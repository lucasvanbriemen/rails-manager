require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "socket"

# The replacement for Plesk's /opt/psa/bin/mysqldump.sh.
#
# That script, fired once a day from /etc/cron.daily/50plesk-daily, is the ONLY
# automatic backup this server has. It disappears with the licence on
# 2026-09-01 and its absence is invisible — no error, no log line, no alert —
# until somebody needs a restore and discovers there is nothing to restore from.
#
# Four properties this class is built around, in the order they matter:
#
#   1. NOTHING IS OMITTED SILENTLY. gitub_gui is 18.6 GB and 18.25 of those are
#      one table (incoming_webhooks, 896k rows of raw GitHub payloads). Some
#      exclusion is unavoidable — including it would make a 17-directory
#      retention schedule cost ~320 GB against 274 GB free — so the exclusion is
#      a named POLICY with a written reason, it is recorded on the Backup row,
#      it is written into the manifest, and the excluded table's SCHEMA is still
#      dumped so a restore rebuilds it empty rather than missing. A backup that
#      quietly drops data is worse than one that fails, because the failure gets
#      noticed.
#
#   2. IT IS VERIFIED. Every run restores one dump into a scratch database and
#      compares it table-for-table and row-for-row against counts captured at
#      dump time — not against the live database, whose rows move under you and
#      would make every verification a coin toss. The scratch database is
#      dropped in an ensure. A backup nobody has restored is not a backup.
#
#   3. SQLITE IS NEVER `cp`'d. 24 SQLite files across 7 apps, every one of them
#      WAL-mode and live. `cp` of a WAL database copies the main file without
#      the -wal beside it and produces a file that opens fine and is missing the
#      most recent transactions. `sqlite3 .backup` uses the online backup API
#      and is the only correct answer.
#
#   4. THE PLAN IS TYPED, NOT A COMMAND LINE. The manager runs as `ltvb`, a uid
#      eight internet-facing apps share, and cannot read the webspaces (0750),
#      /etc/ltvb, the crontabs or the MariaDB credentials. Everything privileged
#      goes to root — and by the same rule Agent already states for nginx, what
#      crosses that boundary is a spec (database name, mode, table names, a path
#      from a fixed list), never a string root would execute. See Delegated.
#
# Off-server, and in the test suite, `call` runs the plan in-process against a
# temp tree. On the server it is either a root `rake backup:run` or the same
# plan handed to the agent.
class BackupRunner
  # A phase could not do its job. Aborts the run and is recorded on the row.
  class Failed < StandardError; end
  # An identifier or destination path we are not willing to put in a shell-less
  # argv, an SQL identifier, or an sqlite dot-command. Never escaped, only
  # refused — the same rule SystemdUnit applies to unit files.
  class Unsafe < StandardError; end

  ROOT = "/var/backups/ltvb".freeze

  # The whole tree is 0700/0600, and the reason is what is in it: the MariaDB
  # grant tables, the psa database, 23 .env files, 3 config/master.key, and
  # tarballs of /etc/postfix and /etc/dovecot that carry four TLS private keys
  # which are root-only where they live. Root's umask on this box is 0022, so
  # without both of these a run lands 0755/0644 on a machine six webspace uids
  # and www-data share. The incumbent this replaces is stricter —
  # /var/lib/psa/dumps/mysql.daily.dump.0.gz is 0600 — and ltvb-agentd already
  # states the same rule for its own .bak files.
  #
  # The umask is process-wide for the duration of the run, which is correct for
  # the two ways this actually runs (a root `rake backup:run`, or the agent) and
  # is one more reason a backup is not something to start from a request thread.
  DIR_MODE   = 0o700
  FILE_UMASK = 0o077

  # Second-resolution UTC, lexically sortable, unambiguous in a directory
  # listing next to a filename that also contains dots.
  STAMP_FORMAT = "%Y%m%dT%H%M%SZ".freeze
  # What STAMP_FORMAT produces, as a matcher: a directory under the root is one
  # of ours only if its name has this exact shape.
  STAMP_PATTERN = /\A\d{8}T\d{6}Z\z/

  MYSQL_DIR     = "mysql".freeze
  SQLITE_DIR    = "sqlite".freeze
  FILES_DIR     = "files".freeze
  SYSTEM_DIR    = "system".freeze
  MANIFEST_NAME = "manifest.json".freeze

  # ---- MariaDB --------------------------------------------------------------

  # Skipped outright. information_schema and performance_schema are views over
  # server state and cannot be restored; `sys` is a package of views and
  # routines that the server ships and recreates, so a dump of it restores
  # objects that already exist and fails.
  SYSTEM_SCHEMAS = %w[information_schema performance_schema sys].freeze

  # Kept on purpose, and listed here so nobody "tidies" them away later:
  #
  #   psa            Plesk's own configuration database. The licence dies, the
  #                  records do not — it is the reference for every mail user,
  #                  vhost and subscription this migration is reproducing, and
  #                  /root/plesk-export was derived FROM it.
  #   roundcubemail  webmail identities, contacts and per-user settings. Nine
  #                  mailboxes' worth, and not reconstructible from the Maildirs.
  #   mysql          the grant tables. Losing them loses every application's
  #                  database credentials at the moment they are needed most.
  DELIBERATELY_KEPT = %w[psa roundcubemail mysql].freeze

  # --single-transaction: a consistent snapshot from InnoDB without locking the
  #   tables, which matters because gitub_gui is written to continuously.
  # --routines/--events/--triggers: mysqldump's default is to dump NONE of
  #   these, so a restore from a default dump silently loses every stored
  #   procedure, scheduled event and trigger.
  # --hex-blob: binary columns survive the round trip through a text dump.
  # --default-character-set=utf8mb4: the client charset decides how the dump is
  #   encoded; the server default here is not utf8mb4 for every database.
  # `--opt` is on by default and brings --quick with it, so an 18 GB table
  # streams rather than being buffered into the dumper's memory.
  MYSQLDUMP_FLAGS = %w[
    --single-transaction --routines --events --triggers --hex-blob
    --default-character-set=utf8mb4
  ].freeze

  # Credentials NEVER travel in argv: /proc/<pid>/cmdline is world-readable and
  # six unrelated webspace uids share this box. They live in a root-owned
  # my.cnf-format file named by path, and --defaults-file has to be mysqldump's
  # FIRST argument or it is ignored.
  DEFAULTS_FILE          = "/etc/ltvb/backup.cnf".freeze
  # Debian's maintenance account. Already on the box, already root-only, and a
  # working fallback until /etc/ltvb/backup.cnf is installed.
  FALLBACK_DEFAULTS_FILE = "/etc/mysql/debian.cnf".freeze

  # Database and table names are interpolated into SQL identifiers and into
  # filenames, so they are validated rather than quoted. Deliberately narrow:
  # this server really does have databases called "email.lucasvanbriemen.nl"
  # and "voordezorgmanement.nl", so dots and hyphens are in — backticks,
  # quotes, spaces, backslashes and newlines are not, and anything holding one
  # is refused instead of escaped.
  DB_NAME    = /\A[A-Za-z0-9_.-]{1,64}\z/
  IDENTIFIER = /\A[A-Za-z0-9_$]{1,64}\z/

  # The scratch database restore verification uses. The prefix is fixed and
  # checked twice — once when the name is minted, once immediately before the
  # DROP — because DROP DATABASE is the single most destructive statement in
  # this file and it must never be able to name a real one.
  SCRATCH_PREFIX = "ltvb_verify_".freeze
  SCRATCH_NAME   = /\A#{SCRATCH_PREFIX}[a-f0-9]{16}\z/

  # information_schema.table_rows is an ESTIMATE for InnoDB — off by tens of
  # percent — so it is useless for proving a restore. Counts come from COUNT(*),
  # batched so a 200-table schema is a handful of statements rather than 200.
  COUNT_BATCH = 50

  # ---- per-database policy --------------------------------------------------

  # :full          dump structure and data (the default; no Policy row needed)
  # :schema_only   dump structure, no data at all
  # :exclude_tables  dump structure for everything, data for everything except
  #                  the named tables
  MODES = %i[full schema_only exclude_tables].freeze

  # Normalised in the readers rather than in an initialize override, so a Policy
  # built from JSON (string mode, string table names) and one written as a
  # literal here behave identically — and an unknown mode raises at the moment
  # it would be used to build a command, not silently falls through to :full.
  Policy = Struct.new(:mode, :tables, :reason, keyword_init: true) do
    def mode
      value = (self[:mode].presence || :full).to_sym
      raise Unsafe, "unknown backup mode #{self[:mode].inspect}" unless MODES.include?(value)

      value
    end

    def tables = Array(self[:tables]).map(&:to_s)

    def full?          = mode == :full
    def schema_only?   = mode == :schema_only
    def excludes_data? = !full?
  end

  DEFAULT_POLICY = Policy.new(mode: :full, tables: [], reason: nil).freeze

  # The one exclusion this server needs, spelled out. Everything about it is
  # deliberate: the table, the reason, the arithmetic behind the reason, and the
  # fact that its CREATE TABLE is still dumped.
  POLICIES = {
    "gitub_gui" => Policy.new(
      mode: :exclude_tables,
      tables: %w[incoming_webhooks],
      reason: "18.25 GB of the database's 18.6 GB, in 896k rows of raw GitHub webhook " \
              "payloads that were already processed into workflow_jobs, commits and " \
              "pull_request_comments. Dumping it makes every run 18 GB and the retention " \
              "schedule unaffordable (~320 GB against 274 GB free). The table's structure " \
              "IS dumped, so a restore rebuilds it empty rather than missing — every " \
              "foreign key and query against it still resolves."
    ).freeze
  }.freeze

  def self.policy_for(database)
    POLICIES.fetch(database.to_s, DEFAULT_POLICY)
  end

  # ---- files ----------------------------------------------------------------

  # What a checkout holds that a `git reset --hard` and a deploy cannot bring
  # back. Deliberately short — everything not listed is either code (git),
  # rebuilt (vendor/, node_modules/, public/assets), or noise a restore does not
  # want (logs, tmp, framework caches).
  #
  # Split by runtime because the same idea has two spellings: Laravel keeps user
  # uploads in storage/app, Rails' ActiveStorage disk service writes into
  # storage/ itself — which is also where the SQLite databases live, hence the
  # *.sqlite3 exclusions below. Those are the SQLite phase's job, and copying
  # them a second time with tar would be exactly the `cp` of a live WAL database
  # this class exists to avoid.
  RUBY_APP_FILES = %w[.env config/master.key storage].freeze
  PHP_APP_FILES  = %w[.env storage/app].freeze

  TAR_EXCLUDES = %w[
    vendor */vendor node_modules */node_modules .git */.git tmp */tmp
    *.log *.sqlite3 *.sqlite3-shm *.sqlite3-wal *.sqlite3-journal
    storage/framework storage/logs storage/debugbar
  ].freeze

  # Per-APP file exclusions, held to exactly the rules POLICIES is held to: a
  # named target, a written reason, recorded on the Backup row and in the
  # manifest. Keyed by App#name.
  #
  # This exists because RUBY_APP_FILES tars `storage`, and one app's storage is
  # not documents: /var/www/vhosts/ltvb.nl/music.ltvb.nl/storage/audio is 6.3 GB
  # in 835 mp3s that gzip cannot touch (measured ratio 0.996 on a real file), and
  # storage/kokoro is a 315 MB HuggingFace model cache that re-downloads. Total
  # measured across every app's storage: 6.74 GB. Without this a run is ~6.9 GB
  # rather than the ~1 GB the retention arithmetic assumes, and 17 retained runs
  # are ~118 GB — on the same single filesystem (/dev/vda1, 274 GB free) as the
  # data they are protecting.
  #
  # storage/audio is the one entry here that is NOT reconstructible from git or
  # from the internet, so this is a KNOWN GAP and not a solved problem: those
  # files need a copy off this box by some other route. Recording it as an
  # exclusion is what keeps that fact in front of whoever reads a backup report,
  # instead of in a comment nobody opens.
  APP_FILE_EXCLUSIONS = {
    "music.ltvb.nl" => {
      paths: %w[storage/audio storage/kokoro],
      reason: "6.3 GB of mp3 in storage/audio (835 files; gzip ratio 0.996, so compression buys " \
              "nothing) plus a 315 MB re-downloadable HuggingFace model cache in storage/kokoro. " \
              "Together they are ~95% of every run and the reason a 17-directory retention " \
              "schedule would cost ~118 GB against 274 GB free. storage/audio still needs a copy " \
              "off this box by another route — it is excluded, not protected elsewhere."
    }
  }.freeze

  # Where SQLite files are looked for inside a checkout. NOT `**` from the app
  # root: vendor/ and node_modules/ ship .sqlite3 test fixtures by the dozen,
  # and a full-tree glob across 25 checkouts is slow enough to matter in a
  # nightly job. `shared` is here for the release layout, where the real file
  # lives in shared/storage and current/storage is a symlink to it.
  SQLITE_GLOBS = %w[*.sqlite3 storage/**/*.sqlite3 db/**/*.sqlite3 database/**/*.sqlite3 shared/**/*.sqlite3].freeze

  # Config that is not in any git repo and would have to be reconstructed by
  # hand, plus the four things a restore cannot rebuild from anything else.
  # /etc/ltvb is the manager's own (nginx sites, agent templates, TLS), and the
  # crontabs are the last unmodelled thing that starts processes here.
  #
  #   /var/qmail/mailnames  144 MB of real mail in 9 Maildirs. /etc/postfix and
  #                         /etc/dovecot describe who RECEIVES mail; this is the
  #                         mail itself, and this box is the MX for ltvb.nl,
  #                         lucasvanbriemen.nl and voordezorgmanagement.nl.
  #                         TAR_EXCLUDES drops Maildir/tmp and dovecot.index.log
  #                         from the archive, which is harmless: tmp/ holds
  #                         deliveries still in flight and Dovecot recreates both
  #                         it and the indexes from cur/ and new/.
  #   /etc/letsencrypt      all 20 certificates AND their private keys (live/ and
  #                         archive/ are 0700). Re-issuing needs working DNS and
  #                         a working web tier, which is exactly what is missing
  #                         while a restore is being done.
  #   /etc/domainkeys       the DKIM private keys for four domains. Losing them
  #                         breaks signing until new keys are generated and every
  #                         DNS TXT record is updated.
  #   /etc/psa              psa.accounts holds 39 symmetrically-encrypted
  #                         passwords, and the key is /etc/psa/private/secret_key
  #                         (16 bytes, 0600 psaadm:root). psa is in
  #                         DELIBERATELY_KEPT as the reference for every mail
  #                         user and vhost; without that key its dump restores as
  #                         noise.
  SYSTEM_PATHS = %w[
    /etc/ltvb /etc/nginx /etc/php /etc/postfix /etc/dovecot /etc/psa
    /etc/letsencrypt /etc/domainkeys /etc/systemd/system /var/spool/cron/crontabs
    /var/qmail/mailnames
  ].freeze

  # Where a checkout nobody registered would be. `sqlite_sources` and
  # `app_file_sets` both enumerate App ROWS, so an app with no row contributes
  # nothing to the manifest — and, without this, nothing to the problem list
  # either, which is precisely the silent omission this class exists to prevent.
  # 24 .sqlite3 files and 23 .env files are on this disk today.
  APP_MARKER_GLOB = "*/*/.env".freeze

  # A destination we are willing to hand to sqlite3's dot-command parser, which
  # is a second parser with its own quoting rules. Every destination this class
  # builds is generated from a validated database name or a slugged path, so
  # this is a backstop, not the primary defence.
  SAFE_DEST = %r{\A/[A-Za-z0-9._/-]+\z}

  # ---- value objects --------------------------------------------------------

  # Two structs rather than one, because the two questions are different — a
  # table inside a database, and a path inside an app — and flattening them
  # would mean writing an app's name into a field called "database" in the
  # manifest. Both answer #target, which is all any reader wants.
  Exclusion = Struct.new(:database, :table, :mode, :reason, keyword_init: true) do
    def target = [ database, table ].compact_blank.join(".")

    def to_h = { database: database, table: table, mode: mode.to_s, reason: reason, target: target }
  end

  FileExclusion = Struct.new(:app, :path, :mode, :reason, keyword_init: true) do
    def target = [ app, path ].compact_blank.join(":")

    def to_h = { app: app, path: path, mode: mode.to_s, reason: reason, target: target }
  end

  # One file in the backup, as it appears in the manifest.
  Item = Struct.new(:kind, :source, :path, :bytes, :sha256, :detail, keyword_init: true) do
    def to_h
      { kind: kind.to_s, source: source, path: path, bytes: bytes, sha256: sha256,
        detail: detail }.compact
    end
  end

  # The typed description of one run: what to dump, from where, with which mode.
  # Pure data — buildable and assertable without a database, a disk or a socket,
  # and the thing that crosses to root (see Delegated).
  Plan = Struct.new(:root, :stamp, :databases, :policies, :sqlite, :app_files,
                    :system_paths, :defaults_file, keyword_init: true) do
    def directory = File.join(root, stamp)

    # Everything this run leaves out, whatever kind of thing it is. One list,
    # because the question a reader has is "what is NOT in here" and it is never
    # "what is not in here, of the MariaDB kind".
    def exclusions
      databases.flat_map { |database| BackupRunner.exclusions_for(database, policies[database]) } +
        app_files.flat_map { |set| BackupRunner.file_exclusions_for(set[:name]) }
    end

    def to_params
      { root: root, stamp: stamp, defaults_file: defaults_file,
        databases: databases.map { |database|
          policy = policies[database]
          { name: database, mode: policy.mode.to_s, exclude_tables: policy.tables }
        },
        sqlite: sqlite, app_files: app_files, system_paths: system_paths }
    end
  end

  # The outcome of comparing a restored database against the counts recorded
  # when it was dumped.
  Comparison = Struct.new(:ok, :tables, :rows, :missing, :extra, :mismatched,
                          :emptied, keyword_init: true) do
    def ok? = !!ok

    def detail
      return "#{tables} tables, #{rows} rows matched#{emptied_note}" if ok?

      problems = []
      problems << "missing tables: #{missing.join(', ')}" if missing.any?
      problems << "unexpected tables: #{extra.join(', ')}" if extra.any?
      problems << "row count mismatch: #{mismatched.map { |t, (e, r)| "#{t} expected #{e}, restored #{r}" }.join('; ')}" if mismatched.any?
      problems.join(" | ")
    end

    def emptied_note
      emptied.blank? ? "" : " (#{emptied.join(', ')} restored empty by policy, as intended)"
    end
  end

  # ---- shell ----------------------------------------------------------------

  # Every process this class starts goes through one small object so the tests
  # can assert on argv without running mysqldump, and so a run can be pointed at
  # a recorder instead of the machine.
  class Shell
    # `code` is kept because one caller needs to tell tar's exit statuses apart:
    # GNU tar exits 1 for "a file changed while being read", which is routine on
    # a live server and produces a perfectly good archive, and 2 for a real
    # failure. Collapsing both into ok:false would make every nightly run
    # PARTIAL and drain the word of its meaning.
    Result = Struct.new(:ok, :out, :err, :code, keyword_init: true) do
      def ok? = !!ok
    end

    def capture(argv)
      out, err, status = Open3.capture3(*argv)
      Result.new(ok: status.success?, out: out, err: err, code: status.exitstatus)
    rescue SystemCallError, IOError => e
      Result.new(ok: false, out: "", err: "#{e.class}: #{e.message}")
    end

    # argvs are chained stdout-to-stdin and the last one's stdout is APPENDED to
    # `out`. Appending is what lets a two-pass dump (structure, then data) land
    # in one .sql.gz: concatenated gzip members are a valid gzip stream and
    # gunzip decompresses them as one file.
    #
    # No shell anywhere. A `"mysqldump ... | gzip > #{path}"` string would put
    # every database name on this box — including "email.lucasvanbriemen.nl" —
    # through a shell parser.
    def pipeline(argvs, out:)
      err_read, err_write = IO.pipe
      # Drained in a thread: mysqldump writes warnings to stderr, and a full
      # pipe buffer would deadlock the pipeline against a parent that only
      # starts reading after the children exit.
      drain = Thread.new { err_read.read }

      statuses = File.open(out, "ab") { |sink| Open3.pipeline(*argvs, out: sink, err: err_write) }

      err_write.close
      err = drain.value.to_s
      err_read.close

      failed = statuses.each_with_index.reject { |status, _index| status.success? }
      messages = failed.map { |status, index| "#{argvs[index].first} exited #{status.exitstatus}" }
      Result.new(ok: failed.empty?, out: "", code: statuses.last&.exitstatus,
                 err: ([ err ] + messages).compact_blank.join("\n"))
    rescue SystemCallError, IOError => e
      Result.new(ok: false, out: "", err: "#{e.class}: #{e.message}")
    end
  end

  # ---- pure argv builders ---------------------------------------------------

  class << self
    # The mysqldump invocations for one database, in order. Two passes are
    # needed for :exclude_tables and the reason is not obvious:
    # --ignore-table drops the table's CREATE as well as its rows, so a
    # single-pass dump restores a database where the excluded table does not
    # exist — every foreign key and every query naming it breaks. Pass one dumps
    # structure for EVERYTHING (--no-data), pass two dumps data for everything
    # but the excluded tables (--no-create-info).
    def dump_passes(database, policy: policy_for(database), defaults_file: DEFAULTS_FILE)
      name = database_name!(database)
      base = [ "mysqldump", "--defaults-file=#{defaults_file}", *MYSQLDUMP_FLAGS ]

      case policy.mode
      when :full
        [ base + [ name ] ]
      when :schema_only
        [ base + [ "--no-data", name ] ]
      when :exclude_tables
        ignores = policy.tables.map { |table| "--ignore-table=#{name}.#{identifier!(table)}" }
        [ base + [ "--no-data", name ],
          base + [ "--no-create-info", *ignores, name ] ]
      end
    end

    # What this policy leaves out, as data rather than prose. Empty for :full —
    # and an empty list is a positive statement ("nothing was omitted"), which
    # is why Backup#exclusion_summary says so out loud instead of rendering "".
    def exclusions_for(database, policy = policy_for(database))
      case policy.mode
      when :full         then []
      when :schema_only  then [ Exclusion.new(database: database, table: nil, mode: :schema_only, reason: policy.reason) ]
      when :exclude_tables
        policy.tables.map do |table|
          Exclusion.new(database: database, table: table, mode: :exclude_tables, reason: policy.reason)
        end
      end
    end

    # The same statement for an app's files. An app with no entry excludes
    # nothing, and an empty list is a positive answer, not a missing one.
    def file_exclusions_for(app_name)
      policy = APP_FILE_EXCLUSIONS[app_name.to_s]
      return [] unless policy

      policy[:paths].map do |path|
        FileExclusion.new(app: app_name.to_s, path: path, mode: :exclude_paths, reason: policy[:reason])
      end
    end

    def excluded_paths_for(app_name) = APP_FILE_EXCLUSIONS.dig(app_name.to_s, :paths) || []

    # `sqlite3 <source> ".backup '<dest>'"`. NOT cp: 24 of these files are live
    # WAL databases, and copying the main file without its -wal sibling produces
    # a database that opens cleanly and is missing the newest transactions —
    # a corruption you only discover from the data, months later.
    #
    # `dest` is validated because it is re-parsed by sqlite's own dot-command
    # lexer, where a quote is a quote again.
    def sqlite_argv(source, dest)
      [ "sqlite3", source.to_s, ".backup '#{safe_dest!(dest)}'" ]
    end

    # tar from inside the app so the archive holds relative paths (a restore
    # into a different directory is the normal case), with the build artefacts
    # and the SQLite files excluded by pattern as well as by the include list.
    #
    # `excludes` are the per-app POLICY exclusions on top of that. They are
    # passed in rather than looked up here because tar_argv is also what builds
    # the system-config archives, which have no app and no policy.
    def tar_argv(dest, chdir:, entries:, excludes: [])
      raise Unsafe, "refusing to tar an empty entry list into #{dest}" if entries.empty?

      patterns = TAR_EXCLUDES + Array(excludes).map(&:to_s)
      [ "tar", "--create", "--gzip", "--file", safe_dest!(dest), "--directory", chdir.to_s,
        *patterns.map { |pattern| "--exclude=#{pattern}" }, *entries ]
    end

    # A batched COUNT(*) statement. information_schema.table_rows is an estimate
    # for InnoDB and cannot be compared against anything, so the counts that go
    # in the manifest — and therefore the counts verification proves — are real.
    def count_query(database, tables)
      name = database_name!(database)
      tables.map do |table|
        column = identifier!(table)
        "SELECT '#{column}', COUNT(*) FROM `#{name}`.`#{column}`"
      end.join(" UNION ALL ")
    end

    # Compare a restored database against the counts recorded when it was
    # dumped. Deliberately NOT against the live database: gitub_gui takes
    # webhooks continuously, so live counts move between the dump and the
    # verification and every run would fail for a reason that is not a fault.
    #
    # `emptied` names tables the policy left without data. They are expected at
    # zero — they are in `expected` with a count of 0 — and are listed
    # separately so a passing verification still says which tables came back
    # empty on purpose.
    def compare_counts(expected:, restored:, emptied: [])
      expected = expected.transform_keys(&:to_s).transform_values(&:to_i)
      restored = restored.transform_keys(&:to_s).transform_values(&:to_i)

      missing = expected.keys - restored.keys
      extra   = restored.keys - expected.keys
      mismatched = expected.filter_map do |table, count|
        [ table, [ count, restored[table] ] ] if restored.key?(table) && restored[table] != count
      end.to_h

      Comparison.new(
        ok: missing.empty? && extra.empty? && mismatched.empty?,
        tables: expected.size, rows: expected.values.sum,
        missing: missing, extra: extra, mismatched: mismatched,
        emptied: Array(emptied).map(&:to_s)
      )
    end

    def scratch_name(random: SecureRandom.hex(8))
      name = "#{SCRATCH_PREFIX}#{random}"
      raise Unsafe, "generated scratch name #{name.inspect} is not a scratch name" unless name.match?(SCRATCH_NAME)

      name
    end

    # ---- validators (never escape, only refuse) ----------------------------

    def database_name!(name)
      value = name.to_s
      return value if value.match?(DB_NAME) && !SYSTEM_SCHEMAS.include?(value)

      raise Unsafe, "refusing #{name.inspect} as a database name"
    end

    def identifier!(name)
      value = name.to_s
      return value if value.match?(IDENTIFIER)

      raise Unsafe, "refusing #{name.inspect} as an SQL identifier"
    end

    def safe_dest!(path)
      value = path.to_s
      return value if value.match?(SAFE_DEST) && !value.include?("..")

      raise Unsafe, "refusing #{path.inspect} as a backup destination"
    end

    # "/var/www/vhosts/ltvb.nl/git.ltvb.nl/storage/production.sqlite3" =>
    # "ltvb.nl-git.ltvb.nl-storage-production.sqlite3". Flat, collision-free
    # across webspaces, and still readable — five apps have a file called
    # production_queue.sqlite3 and a basename-only scheme would lose four.
    def slug(path)
      File.expand_path(path.to_s)
          .delete_prefix("#{App::VHOSTS_ROOT}/")
          .delete_prefix("/")
          .gsub(%r{[/\s]+}, "-")
          .gsub(/[^A-Za-z0-9._-]/, "_")
    end
  end

  # ---- run ------------------------------------------------------------------

  # apps:      what to walk for SQLite files and uploads. Injected so the tests
  #            can hand it two App objects rooted in a temp directory.
  # databases: the MariaDB schema list. nil means "ask the server".
  # verify:    false only for a deliberate skip, which is recorded as
  #            verify_status "skipped" rather than left looking unverified.
  def initialize(root: ROOT, now: Time.now.utc, stamp: nil, apps: nil, databases: nil,
                 system_paths: nil, defaults_file: nil, shell: Shell.new, verify: true,
                 host: nil, backup: nil, vhosts_root: App::VHOSTS_ROOT)
    @root          = root.to_s
    @now           = now.utc
    @stamp         = stamp.presence
    @apps          = apps
    @databases     = databases
    @system_paths  = system_paths
    @defaults_file = defaults_file.presence
    @shell         = shell
    @verify        = verify
    @host          = host || Socket.gethostname
    @backup        = backup
    @vhosts_root   = vhosts_root.to_s
    @items         = []
    @problems      = []
  end

  attr_reader :backup, :problems

  # Re-open a run that already happened, so an older backup can be re-proved
  # (`rake backup:verify`) rather than only ever verified by the run that took
  # it. The stamp comes from the directory on the row, never from the clock: the
  # manifest is a map, and a map only means anything against its own directory.
  def self.for(backup, **options)
    path = backup.path.to_s
    new(root: File.dirname(path), stamp: File.basename(path), backup: backup, **options)
  end

  # The credentials file the PLAN names. A statement of intent, never a probe
  # result: the plan is built by the manager (uid 10006), which can read neither
  # candidate — /etc/mysql/debian.cnf is 0600 root:root and /etc/ltvb is
  # root-only — so a `File.readable?` here would always answer "no" and the
  # project's own credentials file could never be selected by the process that
  # builds the plan, however long ago it was installed. Root resolves the
  # fallback; see resolved_defaults_file and Delegated.
  def defaults_file = @defaults_file || DEFAULTS_FILE

  # The file this process will actually hand to mysql/mysqldump. The probe lives
  # here because this runs in whoever executes the commands — root, under
  # `rake backup:run` — and Debian's maintenance account is the working fallback
  # until /etc/ltvb/backup.cnf exists. A file named explicitly by the caller is
  # used as given and never second-guessed.
  def resolved_defaults_file
    @resolved_defaults_file ||=
      if @defaults_file || File.readable?(DEFAULTS_FILE)
        defaults_file
      else
        FALLBACK_DEFAULTS_FILE
      end
  end

  def stamp     = @stamp ||= @now.strftime(STAMP_FORMAT)
  def directory = File.join(@root, stamp)

  # The typed spec for this run. Building it touches nothing — but it does look,
  # and what it cannot find is recorded here rather than discovered later.
  def plan
    @plan ||= begin
      note_unregistered_checkouts
      Plan.new(
        root: @root, stamp: stamp, defaults_file: defaults_file,
        databases: dumpable_databases,
        policies: dumpable_databases.index_with { |database| self.class.policy_for(database) },
        sqlite: sqlite_sources, app_files: app_file_sets, system_paths: existing_system_paths
      )
    end
  end

  def call
    # Everything written from here on is 0600 in a 0700 tree; see FILE_UMASK.
    # Restored in the ensure, because a process left with a 077 umask would
    # create unreadable files for whatever ran next.
    previous_umask = File.umask(FILE_UMASK)

    # Built before the row exists, so the row can carry the exclusions from the
    # moment it is created rather than acquiring them at the end of a run that
    # might not reach the end.
    exclusions = plan.exclusions
    planning_problems = @problems.dup

    @backup ||= Backup.create!(path: directory, host: @host, status: Backup::RUNNING,
                               started_at: @now, excluded: exclusions.map(&:to_h))
    log "== backup #{stamp} on #{@host} ==\n"
    announce_exclusions
    planning_problems.each { |problem| log "  WARN #{problem}\n" }

    FileUtils.mkdir_p(@root, mode: DIR_MODE)
    FileUtils.mkdir_p([ mysql_dir, sqlite_dir, files_dir, system_dir ], mode: DIR_MODE)
    # Explicit, because mkdir_p leaves the mode of a directory that already
    # existed alone — and a re-run into an existing stamp must not inherit
    # whatever mode that directory happened to have.
    FileUtils.chmod(DIR_MODE, directory)

    dump_databases!
    copy_sqlite!
    archive_app_files!
    archive_system_config!
    write_manifest!

    status = @problems.empty? ? Backup::SUCCEEDED : Backup::PARTIAL
    @backup.finish!(status, at: Time.current, error: @problems.presence&.join("\n"))
    log "\n== #{status} — #{@items.size} files, #{total_bytes} bytes ==\n"

    verify!
    @backup
  rescue StandardError => e
    log "\n== FAILED: #{e.class}: #{e.message} ==\n"
    @backup&.finish!(Backup::FAILED, at: Time.current, error: "#{e.class}: #{e.message}")
    @backup || raise
  ensure
    File.umask(previous_umask) if previous_umask
  end

  # Restore one dump into a scratch database, compare it against the counts
  # recorded at dump time, drop the scratch. This is the step that turns a
  # directory of files into a backup.
  #
  # The sample is the smallest FULL dump THAT HAS ROWS: smallest because the
  # nightly run has to finish, full because a schema-only dump proves nothing
  # about the data path, and non-empty for exactly the same reason. The database
  # that was used is recorded on the row — "verified" that does not say what it
  # verified is a claim, not evidence.
  # `scratch` is nameable so a re-run can be told apart in the server's process
  # list; it is validated against SCRATCH_NAME either way, because the name that
  # comes in here is the name a DROP DATABASE goes out with.
  def verify!(database: nil, scratch: nil)
    return @backup.skip_verification!("verification disabled for this run") unless @verify

    entry = verification_candidate(database)
    unless entry
      return @backup.skip_verification!(
        "no full mysql dump with any rows in this run to restore — there is nothing whose " \
        "journey through dump, gzip and restore could be proved")
    end

    scratch = scratch.presence || self.class.scratch_name
    raise Unsafe, "refusing #{scratch.inspect} as a scratch database" unless scratch.match?(SCRATCH_NAME)

    log "\n--- verify restore of #{entry[:source]} into #{scratch} ---\n"

    existing = mysql_values("SHOW DATABASES")
    if existing.include?(scratch)
      raise Failed, "scratch database #{scratch} already exists — refusing to touch it"
    end

    begin
      run_sql!("CREATE DATABASE `#{scratch}`")
      restore!(File.join(directory, entry[:path]), scratch)
      compare_restore(entry, scratch)
    ensure
      drop_scratch!(scratch)
    end
  rescue StandardError => e
    log "verification failed: #{e.class}: #{e.message}\n"
    @backup.record_verification!(passed: false, database: database, detail: "#{e.class}: #{e.message}")
  end

  # Delete the directories retention no longer protects. The rows stay: "there
  # WAS a verified backup on the 3rd and it is gone now" is a far more useful
  # statement than silence, and Backup#pruned_at is what makes it possible.
  def prune!(now: Time.current, dry_run: false)
    # If the root itself is missing, every row looks like a ghost and every
    # directory looks already deleted. That is a mount or a typo, not a
    # retention outcome, and rewriting the whole history to agree with it is far
    # worse than doing nothing.
    unless Dir.exist?(@root)
      note "backup root #{@root} does not exist — refusing to prune or to record anything as pruned"
      return []
    end

    Backup.abandon_stale_runs!(now: now) unless dry_run
    reconcile_ghosts!(dry_run: dry_run)

    Backup.prunable(now: now).select do |old|
      next true if dry_run

      path = prunable_path!(old)
      FileUtils.rm_rf(path)
      # rm_rf is force-silent. Without this check a delete that failed (a
      # read-only mount, an immutable file) would still be recorded as a prune,
      # and the `on_disk` scope would then hide the row from every future prune
      # while the bytes sat on the disk forever.
      if Dir.exist?(path)
        note "#{path} could not be deleted — the row is left on disk so the next prune retries it"
        next false
      end

      old.mark_pruned!
      true
    end
  end

  # Directories under the root that no row knows about. Reported, never deleted,
  # and the reason is specific: the manager's own SQLite database is INSIDE the
  # backup, so the moment it is restored or reset every directory taken after
  # that snapshot becomes an orphan — and a sweep would delete the NEWEST
  # backups first. Naming them is what this class can honestly do; deciding is
  # for a human with a `du`.
  def orphan_directories
    return [] unless Dir.exist?(@root)

    known = Backup.pluck(:path).map { |path| File.basename(path.to_s) }.to_set
    Dir.children(@root)
       .select { |name| name.match?(STAMP_PATTERN) && !known.include?(name) }
       .sort.map { |name| File.join(@root, name) }
  end

  private

  # ---- phases ---------------------------------------------------------------

  def dump_databases!
    log "\n--- mysql (#{plan.databases.size} databases) ---\n"

    plan.databases.each do |database|
      policy = plan.policies[database]
      dest   = File.join(mysql_dir, "#{database}.sql.gz")
      File.delete(dest) if File.exist?(dest)

      counts = policy.schema_only? ? {} : table_counts(database, skip: policy.tables)
      # An excluded table is recorded as zero rows EXPECTED, not as absent: its
      # CREATE is in the dump, so a restore must produce the table, empty.
      policy.tables.each { |table| counts[table] = 0 }

      self.class.dump_passes(database, policy: policy, defaults_file: resolved_defaults_file).each do |argv|
        result = @shell.pipeline([ argv, [ "gzip", "-9" ] ], out: dest)
        raise Failed, "mysqldump #{database}: #{result.err.presence || 'failed'}" unless result.ok?
      end

      record(kind: "mysql", source: database, path: dest,
             detail: { mode: policy.mode.to_s, table_rows: counts })
      log "  #{database} (#{policy.mode}, #{counts.size} tables, #{counts.values.sum} rows)\n"
    end
  end

  # One of the files copied here is the manager's OWN database — the one this
  # run is writing its Backup row into as it goes. That is exactly the case
  # `.backup` exists for: the online backup API takes a consistent snapshot of a
  # database being written to, so the copy is valid and simply shows the run as
  # still `running`. A `cp` here would copy a torn page mid-transaction.
  def copy_sqlite!
    log "\n--- sqlite (#{plan.sqlite.size} files) ---\n"

    plan.sqlite.each do |source|
      dest = File.join(sqlite_dir, self.class.slug(source))
      File.delete(dest) if File.exist?(dest)

      result = @shell.capture(self.class.sqlite_argv(source, dest))
      unless result.ok? && File.exist?(dest)
        note "sqlite #{source}: #{result.err.presence || 'no output file'}"
        next
      end

      gzip = @shell.capture([ "gzip", "-9", "-f", dest ])
      raise Failed, "gzip #{dest}: #{gzip.err}" unless gzip.ok?

      record(kind: "sqlite", source: source, path: "#{dest}.gz")
      log "  #{source}\n"
    end
  end

  def archive_app_files!
    log "\n--- app files (#{plan.app_files.size} apps) ---\n"

    plan.app_files.each do |set|
      dest = File.join(files_dir, "#{self.class.slug(set[:path])}.tar.gz")
      excludes = Array(set[:excludes])
      result = @shell.capture(self.class.tar_argv(dest, chdir: set[:path], entries: set[:entries],
                                                  excludes: excludes))
      unless usable_archive?(result, dest)
        note "tar #{set[:name]}: #{result.err.presence || 'failed'}"
        next
      end

      record(kind: "files", source: set[:path], path: dest,
             detail: { entries: set[:entries], excludes: excludes })
      log "  #{set[:name]}: #{set[:entries].join(', ')}#{excludes.any? ? " (without #{excludes.join(', ')})" : ''}\n"
    end
  end

  def archive_system_config!
    log "\n--- system config (#{plan.system_paths.size} paths) ---\n"

    plan.system_paths.each do |path|
      dest = File.join(system_dir, "#{self.class.slug(path)}.tar.gz")
      argv = self.class.tar_argv(dest, chdir: File.dirname(path), entries: [ File.basename(path) ])
      result = @shell.capture(argv)
      unless usable_archive?(result, dest)
        note "tar #{path}: #{result.err.presence || 'failed'}"
        next
      end

      record(kind: "system", source: path, path: dest)
      log "  #{path}\n"
    end
  end

  # size + sha256 per file, written into the directory AND onto the row. The
  # copy on the row is the one that survives the disk this backup is sitting on.
  def write_manifest!
    payload = {
      version: 1, host: @host, stamp: stamp, started_at: @now.iso8601,
      finished_at: Time.now.utc.iso8601, root: directory,
      exclusions: plan.exclusions.map(&:to_h),
      items: @items.map(&:to_h), problems: @problems
    }
    File.write(File.join(directory, MANIFEST_NAME), JSON.pretty_generate(payload))
    @backup.update!(manifest: payload[:items], size_bytes: total_bytes, item_count: @items.size)
  end

  # ---- verification ---------------------------------------------------------

  # Smallest by bytes ALONE picks a database with no data in it. On this server
  # the smallest full dump is opendmarc — 1,480 bytes, 9 base tables, COUNT(*)
  # of zero in every one of them — so every nightly run would restore it,
  # compare 0 against 0 and record "passed" without a single row having
  # traversed dump -> gzip -> restore. A truncated gzip member, a broken
  # --hex-blob round trip or a charset mangling in the 29,342 rows of
  # email.lucasvanbriemen.nl would all pass that check. It is deterministic, not
  # a fluke of one night: opendmarc is smallest by an order of magnitude.
  def verification_candidate(database)
    entries = @backup.manifest_entries.select { |entry| entry[:kind] == "mysql" }
    entries = entries.select { |entry| entry.dig(:detail, :mode) != "schema_only" }
    # A database named by hand is honoured as named — the operator is asking
    # "does THIS dump restore" — and compare_restore still refuses to call an
    # empty comparison a pass.
    return entries.find { |entry| entry[:source] == database } if database

    entries.select { |entry| recorded_rows(entry).positive? }.min_by { |entry| entry[:bytes].to_i }
  end

  def recorded_rows(entry) = (entry.dig(:detail, :table_rows) || {}).values.sum { |count| count.to_i }

  def restore!(archive, scratch)
    result = @shell.pipeline([ [ "gzip", "-dc", archive ],
                               [ "mysql", "--defaults-file=#{resolved_defaults_file}", scratch ] ],
                             out: File::NULL)
    raise Failed, "restore into #{scratch}: #{result.err.presence || 'failed'}" unless result.ok?
  end

  def compare_restore(entry, scratch)
    expected = (entry.dig(:detail, :table_rows) || {}).to_h
    emptied  = plan.policies[entry[:source]]&.tables || []
    restored = table_counts(scratch)
    result   = self.class.compare_counts(expected: expected, restored: restored, emptied: emptied)

    log "  #{result.detail}\n"
    # "Passed" has to mean data moved. A comparison of zero against zero agrees
    # perfectly and proves nothing, so it is recorded as SKIPPED — an honest
    # "not attempted" — rather than as the one piece of evidence this whole
    # class exists to produce.
    if result.ok? && result.rows.zero?
      return @backup.skip_verification!(
        "#{entry[:source]} restored, but the dump holds no rows: 0 == 0 is not evidence that " \
        "anything survives dump, gzip and restore")
    end

    @backup.record_verification!(passed: result.ok?, database: entry[:source],
                                 tables: result.tables, rows: result.rows,
                                 detail: result.detail)
  end

  # Always runs, and only ever names the database this run created: the prefix
  # is re-checked here rather than trusted from the variable, because a DROP
  # DATABASE that took its name from anywhere else is the worst bug this file
  # could have.
  def drop_scratch!(scratch)
    raise Unsafe, "refusing to drop #{scratch.inspect}" unless scratch.to_s.match?(SCRATCH_NAME)

    result = run_sql("DROP DATABASE IF EXISTS `#{scratch}`")
    log "  dropped #{scratch}\n" if result.ok?
    note "scratch database #{scratch} could not be dropped: #{result.err}" unless result.ok?
  end

  # ---- mysql plumbing -------------------------------------------------------

  def mysql_argv(*extra) = [ "mysql", "--defaults-file=#{resolved_defaults_file}", "-N", "-B", *extra ]

  def run_sql(statement) = @shell.capture(mysql_argv("-e", statement))

  def run_sql!(statement)
    result = run_sql(statement)
    raise Failed, "#{statement}: #{result.err.presence || 'failed'}" unless result.ok?

    result
  end

  def mysql_values(statement)
    result = run_sql(statement)
    result.ok? ? result.out.to_s.lines.map(&:chomp).reject(&:blank?) : []
  end

  # { table => COUNT(*) }, batched. Tables whose names are not plain identifiers
  # are refused rather than quoted, and refusing here means the whole run stops
  # — a database holding a table we cannot safely name is not one we can claim
  # to have verified.
  def table_counts(database, skip: [])
    name   = self.class.database_name!(database)
    skip   = Array(skip).map(&:to_s)
    tables = mysql_values("SELECT table_name FROM information_schema.tables " \
                          "WHERE table_schema = '#{name}' AND table_type = 'BASE TABLE'") - skip

    tables.each_slice(COUNT_BATCH).each_with_object({}) do |batch, counts|
      result = run_sql(self.class.count_query(name, batch))
      unless result.ok?
        note "row counts for #{name}: #{result.err}"
        next
      end

      result.out.to_s.each_line do |line|
        table, count = line.chomp.split("\t", 2)
        counts[table] = count.to_i if table.present?
      end
    end
  end

  # ---- plan sources ---------------------------------------------------------

  # Every schema on the server minus the ones that cannot be restored. psa,
  # roundcubemail and mysql are NOT filtered — they are in DELIBERATELY_KEPT
  # and that constant exists so a later "these are Plesk's, drop them" cannot
  # happen by accident.
  def dumpable_databases
    @dumpable_databases ||= begin
      names = @databases || mysql_values("SHOW DATABASES")
      names.map(&:to_s).reject { |name| SYSTEM_SCHEMAS.include?(name) }
           .select { |name| name.match?(DB_NAME) }.sort
    end
  end

  def backup_apps
    @backup_apps ||= @apps || App.where(archived_at: nil).order(:name).to_a
  end

  # Deduplicated by real path: a release-layout app reaches the same file
  # through current/storage and shared/storage, and backing it up twice would
  # both waste the run and put two entries in the manifest for one database.
  def sqlite_sources
    @sqlite_sources ||= backup_apps.flat_map { |app|
      SQLITE_GLOBS.flat_map { |pattern| Dir.glob(File.join(app.app_path, pattern)) }
    }.filter_map { |path| real_file(path) }.uniq.sort
  end

  def app_file_sets
    @app_file_sets ||= backup_apps.filter_map do |app|
      wanted  = app.php? ? PHP_APP_FILES : RUBY_APP_FILES
      entries = wanted.select { |entry| File.exist?(File.join(app.app_path, entry)) }
      next if entries.empty?

      { name: app.name, path: app.app_path, entries: entries,
        excludes: self.class.excluded_paths_for(app.name) }
    end
  end

  # A checkout on disk that no App row knows about. Both file walks enumerate
  # rows, so such an app is simply absent from the manifest — the run gets
  # smaller and says nothing, which is the one failure mode this class refuses.
  # Recorded as a problem, so the run is PARTIAL and somebody is told.
  def note_unregistered_checkouts
    known = backup_apps.filter_map { |app| File.expand_path(app.app_path.to_s) }.to_set

    Dir.glob(File.join(@vhosts_root, APP_MARKER_GLOB)).map { |marker| File.dirname(marker) }
       .uniq.sort.reject { |path| known.include?(File.expand_path(path)) }
       .each { |path| note "#{path} looks like an app (it has a .env) but has no App row — nothing in this backup covers it" }
  end

  # Silence about an unreadable /etc/postfix would be the exact failure this
  # class exists to prevent, so a missing path is recorded as a problem — which
  # makes the run PARTIAL — rather than skipped.
  def existing_system_paths
    @existing_system_paths ||= (@system_paths || SYSTEM_PATHS).select do |path|
      readable = File.directory?(path) && File.readable?(path)
      note "system config #{path} is not readable by this process — not in this backup" unless readable
      readable
    end
  end

  # ---- helpers --------------------------------------------------------------

  def mysql_dir  = File.join(directory, MYSQL_DIR)
  def sqlite_dir = File.join(directory, SQLITE_DIR)
  def files_dir  = File.join(directory, FILES_DIR)
  def system_dir = File.join(directory, SYSTEM_DIR)

  def record(kind:, source:, path:, detail: nil)
    @items << Item.new(kind: kind, source: source, bytes: File.size(path),
                       # Relative, because a manifest that hard-codes today's
                       # mount point is useless the moment the backup is moved.
                       path: path.delete_prefix("#{directory}/"),
                       sha256: Digest::SHA256.file(path).hexdigest, detail: detail)
  end

  def total_bytes = @items.sum { |item| item.bytes.to_i }

  # GNU tar exits 1 for "some files differ" — a file that changed while it was
  # being read, which is routine on a live server and still produces a complete,
  # restorable archive. Only 2 (and anything that produced no file) is a
  # failure. Treating 1 as one would mark every nightly run PARTIAL, and a
  # status word that is always the same says nothing.
  def usable_archive?(result, dest)
    return false unless File.exist?(dest)
    return true if result.ok?
    return false unless result.code == 1

    log "  tar reported files changed while reading #{dest} — archive kept\n"
    true
  end

  def real_file(path)
    File.realpath(path) if File.file?(path)
  rescue SystemCallError
    nil
  end

  # rm -rf under a directory this class generates is still rm -rf, so the target
  # has to be a direct child of the configured root and nothing else.
  def prunable_path!(old)
    expanded = File.expand_path(old.path.to_s)
    root     = File.expand_path(@root)
    unless File.dirname(expanded) == root && expanded != root
      raise Unsafe, "refusing to delete #{old.path.inspect}: not a direct child of #{@root}"
    end

    expanded
  end

  # A row whose directory is gone is recorded as pruned, so it stops holding the
  # "newest usable" and "newest verified" protections on behalf of bytes that no
  # longer exist — while the row itself, and therefore the history, survives.
  def reconcile_ghosts!(dry_run: false)
    Backup.ghosts.each do |ghost|
      log "  #{ghost.path} is gone from the disk — recording the row as pruned\n"
      ghost.mark_pruned! unless dry_run
    end
  end

  def announce_exclusions
    exclusions = plan.exclusions
    if exclusions.empty?
      log "no exclusions — every database, table and file is backed up in full\n"
      return
    end

    log "EXCLUSIONS (#{exclusions.size}) — recorded on the Backup row and in the manifest:\n"
    exclusions.each do |exclusion|
      log "  #{exclusion.target} [#{exclusion.mode}]: #{exclusion.reason}\n"
    end
  end

  # A problem, not a failure: the run keeps going and finishes PARTIAL. The
  # distinction matters — an unreadable webspace should not throw away the 19
  # database dumps that did work.
  def note(message)
    @problems << message
    log "  WARN #{message}\n"
  end

  def log(message)
    @backup ? @backup.append_log(message) : message
  end

  # The unprivileged path. See rule 4 in the class comment: the manager cannot
  # read the webspaces, /etc/ltvb, the crontabs or the MariaDB credentials, so a
  # backup started from the web UI hands the PLAN to root instead of doing any
  # of this in process.
  #
  # What crosses is typed — database names, a mode from a closed enum, table
  # names, paths the agent re-derives from its own list — and never a command
  # line, for the same reason Agent gives about nginx: a verb that took a
  # command would make this uid the author of what root executes.
  #
  # ltvb-agentd does not implement these verbs yet. Agent.call answers
  # "agent <version> does not implement backup.run" with ok:false, which is a
  # loud failure rather than a silent no-op — exactly what a missing backup
  # must never be.
  #
  # `defaults_file` in the params is the file the plan WANTS, never a probe
  # result — the uid that builds a plan can read neither candidate, so it cannot
  # answer "does /etc/ltvb/backup.cnf exist" at all. The root side must do what
  # #resolved_defaults_file does here: use the named file if it is there, and
  # fall back to /etc/mysql/debian.cnf if it is not.
  module Delegated
    RUN_VERB    = "backup.run".freeze
    VERIFY_VERB = "backup.verify".freeze
    PRUNE_VERB  = "backup.prune".freeze

    module_function

    def available? = Agent.verbs.include?(RUN_VERB)

    def run(plan, timeout: 3_600)
      Agent.call(RUN_VERB, timeout: timeout, **plan.to_params)
    end

    def verify(stamp:, database: nil, timeout: 900)
      Agent.call(VERIFY_VERB, timeout: timeout, stamp: stamp, database: database)
    end

    def prune(keep:, timeout: 300)
      Agent.call(PRUNE_VERB, timeout: timeout, keep: keep)
    end
  end
end
