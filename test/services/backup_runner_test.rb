require "test_helper"
require "tmpdir"
require "json"

class BackupRunnerTest < ActiveSupport::TestCase
  DEFAULTS = "/etc/ltvb/backup.cnf".freeze

  # A Shell that answers for mysql/mysqldump and lets everything else — sqlite3,
  # tar, gzip — run for real. The point is that the parts this class gets wrong
  # in interesting ways (the `.backup` dot-command, tar's exclude patterns, two
  # gzip members appended into one file, sha256 over the bytes that landed) are
  # exercised against the actual binaries, while MariaDB, which is not on a
  # laptop, is simulated precisely enough to drive verification end to end.
  class FakeMysql < BackupRunner::Shell
    attr_reader :created, :dropped, :dumps, :restores

    # schemas: { "database" => { "table" => row_count } }
    def initialize(schemas: {}, corrupt_restore: nil)
      @schemas         = schemas
      @corrupt_restore = corrupt_restore
      @created         = []
      @dropped         = []
      @dumps           = []
      @restores        = []
      super()
    end

    def capture(argv)
      return super unless argv.first == "mysql"

      answer(argv[argv.index("-e") + 1].to_s)
    end

    # Pretend a database of this name is already on the server.
    def plant(name) = @schemas[name] = {}

    # Substitutes printf for mysqldump and then runs the REAL pipeline, so the
    # gzip member appending that a two-pass dump depends on is genuinely tested.
    def pipeline(argvs, out:)
      if argvs.first.first == "mysqldump"
        @dumps << argvs.first
        database = argvs.first.last
        body = argvs.first.include?("--no-data") ? "-- structure #{database}\n" : "-- data #{database}\n"
        return super([ [ "printf", "%s", body ], *argvs.drop(1) ], out: out)
      end
      return restore(argvs) if argvs.last.first == "mysql"

      super
    end

    private

    # The restored scratch database becomes visible to later count queries,
    # holding whatever the dump said it would: every table, and rows for every
    # table the policy did not exclude — which is exactly what a two-pass
    # --no-data + --ignore-table dump produces. `corrupt_restore` removes one
    # table on the way in, standing in for a dump that did not survive.
    def restore(argvs)
      scratch = argvs.last.last
      source  = File.basename(argvs.first.last, ".sql.gz")
      counts  = (@schemas[source] || {}).dup
      BackupRunner.policy_for(source).tables.each { |table| counts[table] = 0 if counts.key?(table) }
      counts.delete(@corrupt_restore) if @corrupt_restore
      @schemas[scratch] = counts
      @restores << [ source, scratch ]
      BackupRunner::Shell::Result.new(ok: true, out: "", err: "", code: 0)
    end

    def answer(statement)
      case statement
      when "SHOW DATABASES"
        ok(@schemas.keys.join("\n"))
      when /\ACREATE DATABASE `(.+)`\z/
        @created << Regexp.last_match(1)
        @schemas[Regexp.last_match(1)] = {}
        ok("")
      when /\ADROP DATABASE IF EXISTS `(.+)`\z/
        @dropped << Regexp.last_match(1)
        @schemas.delete(Regexp.last_match(1))
        ok("")
      when /table_schema = '(.+?)'/
        ok((@schemas[Regexp.last_match(1)] || {}).keys.join("\n"))
      when /\ASELECT '/
        rows = statement.scan(/SELECT '([^']+)', COUNT\(\*\) FROM `([^`]+)`\.`[^`]+`/)
        ok(rows.map { |table, database| "#{table}\t#{@schemas.dig(database, table).to_i}" }.join("\n"))
      else
        BackupRunner::Shell::Result.new(ok: false, out: "", err: "unexpected: #{statement}", code: 1)
      end
    end

    def ok(out) = BackupRunner::Shell::Result.new(ok: true, out: out, err: "", code: 0)
  end

  # ---- mysqldump argv ------------------------------------------------------

  test "every dump carries the flags that decide what a restore actually contains" do
    argv = BackupRunner.dump_passes("music", defaults_file: DEFAULTS).sole

    # mysqldump defaults to dumping NONE of these, so a restore from a default
    # dump silently loses every routine, event and trigger.
    assert_includes argv, "--single-transaction"
    assert_includes argv, "--routines"
    assert_includes argv, "--events"
    assert_includes argv, "--triggers"
    assert_includes argv, "--hex-blob"
    assert_equal "music", argv.last
  end

  # --defaults-file is ignored unless it is the first argument, and the
  # credentials must never be an argv element: /proc/<pid>/cmdline is world
  # readable and six webspace uids share this box.
  test "credentials arrive as a defaults-file in first position, never as a password" do
    argv = BackupRunner.dump_passes("music", defaults_file: DEFAULTS).sole

    assert_equal "mysqldump", argv[0]
    assert_equal "--defaults-file=#{DEFAULTS}", argv[1]
    assert_empty argv.grep(/--password|-p\S/), "a password must never reach argv"
  end

  test "each database is dumped into its own file rather than one combined dump" do
    with_run(schemas: { "music" => { "songs" => 2 }, "rijles" => { "lessons" => 1 } }) do |backup, dir|
      assert_equal %w[music rijles], backup.entries_of_kind("mysql").map { |e| e[:source] }.sort
      assert_path_exists File.join(dir, "mysql/music.sql.gz")
      assert_path_exists File.join(dir, "mysql/rijles.sql.gz")
    end
  end

  # ---- exclusion policy ----------------------------------------------------

  test "an unconfigured database is dumped whole and excludes nothing" do
    policy = BackupRunner.policy_for("music")

    assert policy.full?
    assert_empty BackupRunner.exclusions_for("music")
    assert_equal 1, BackupRunner.dump_passes("music", defaults_file: DEFAULTS).size
  end

  # The whole point of the two-pass shape: --ignore-table drops the CREATE TABLE
  # as well as the rows, so a one-pass exclusion restores a database in which
  # incoming_webhooks does not exist and every foreign key and query naming it
  # breaks. Pass one takes the structure of everything, pass two the data of
  # everything else.
  test "an excluded table keeps its structure and loses only its rows" do
    structure, data = BackupRunner.dump_passes("gitub_gui", defaults_file: DEFAULTS)

    assert_includes structure, "--no-data"
    assert_empty structure.grep(/--ignore-table/),
                 "the structure pass must cover the excluded table or a restore cannot recreate it"

    assert_includes data, "--no-create-info"
    assert_includes data, "--ignore-table=gitub_gui.incoming_webhooks"
  end

  test "schema-only dumps take no data at all" do
    policy = BackupRunner::Policy.new(mode: :schema_only, reason: "test")
    argv = BackupRunner.dump_passes("music", policy: policy, defaults_file: DEFAULTS).sole

    assert_includes argv, "--no-data"
    assert_empty argv.grep(/--no-create-info/)
  end

  # A backup that quietly omits data is worse than one that fails, so the
  # omission has to be data on the row — with a reason a human can act on — and
  # not a comment in a script somewhere.
  test "an exclusion is recorded with the database, the table and a written reason" do
    exclusion = BackupRunner.exclusions_for("gitub_gui").sole

    assert_equal "gitub_gui", exclusion.database
    assert_equal "incoming_webhooks", exclusion.table
    assert_equal :exclude_tables, exclusion.mode
    assert_match(/18\.25 GB/, exclusion.reason)
    assert_match(/structure IS dumped/, exclusion.reason)
  end

  test "the exclusion reaches the Backup row and the on-disk manifest" do
    with_run(schemas: { "gitub_gui" => { "commits" => 3, "incoming_webhooks" => 896_776 } }) do |backup, dir|
      excluded = backup.exclusion_entries.sole
      assert_equal "gitub_gui", excluded[:database]
      assert_equal "incoming_webhooks", excluded[:table]

      manifest = JSON.parse(File.read(File.join(dir, "manifest.json")))
      assert_equal [ "incoming_webhooks" ], manifest["exclusions"].map { |row| row["table"] }
      assert_match(/incoming_webhooks/, backup.log)
    end
  end

  test "an empty exclusion list says so out loud rather than rendering nothing" do
    backup = Backup.new(excluded: [])

    assert_match(/nothing excluded/, backup.exclusion_summary.sole)
  end

  # ---- identifiers: refused, never escaped ---------------------------------

  test "database and table names that are not plain are refused rather than quoted" do
    # Real names on this host: dots and hyphens have to be allowed.
    assert_equal "email.lucasvanbriemen.nl", BackupRunner.database_name!("email.lucasvanbriemen.nl")
    assert_equal "voordezorgmanement.nl", BackupRunner.database_name!("voordezorgmanement.nl")

    [ "music`; DROP DATABASE psa; --", "music'", "music db", "music\nrijles", "" ].each do |name|
      assert_raises(BackupRunner::Unsafe, "#{name.inspect} must not be accepted") do
        BackupRunner.database_name!(name)
      end
    end
    assert_raises(BackupRunner::Unsafe) { BackupRunner.identifier!("t`x") }
  end

  # A dump of information_schema cannot be restored and a dump of sys restores
  # objects the server already ships.
  test "unrestorable system schemas are refused as dump targets" do
    BackupRunner::SYSTEM_SCHEMAS.each do |schema|
      assert_raises(BackupRunner::Unsafe) { BackupRunner.database_name!(schema) }
    end
  end

  # psa is the reference for the whole migration and roundcubemail is the only
  # copy of nine mailboxes' webmail settings. This test exists so a later
  # "these are Plesk's, drop them" has to argue with a failing test first.
  test "psa, roundcubemail and mysql are kept on purpose" do
    schemas = { "psa" => { "domains" => 6 }, "roundcubemail" => { "users" => 9 },
                "mysql" => { "user" => 12 }, "information_schema" => { "tables" => 1 } }

    with_run(schemas: schemas) do |backup, _dir|
      dumped = backup.entries_of_kind("mysql").map { |entry| entry[:source] }
      assert_equal %w[mysql psa roundcubemail], dumped.sort
      assert_not_includes dumped, "information_schema"
    end
  end

  # ---- sqlite --------------------------------------------------------------

  test "sqlite is copied with the online backup API, never with cp" do
    argv = BackupRunner.sqlite_argv("/tmp/a/production.sqlite3", "/tmp/b/out.sqlite3")

    assert_equal [ "sqlite3", "/tmp/a/production.sqlite3", ".backup '/tmp/b/out.sqlite3'" ], argv
    assert_empty argv.grep(/\Acp\z/)
  end

  # The destination is re-parsed by sqlite's own dot-command lexer, where a
  # quote is a quote again.
  test "a destination sqlite would re-parse is refused" do
    [ "/tmp/it's.sqlite3", "/tmp/../etc/x", "relative.sqlite3", "/tmp/a b" ].each do |dest|
      assert_raises(BackupRunner::Unsafe) { BackupRunner.sqlite_argv("/tmp/a.sqlite3", dest) }
    end
  end

  # The failure this guards against is silent: cp of a WAL database yields a
  # file that opens cleanly and is missing the newest transactions. Here the
  # rows are written, left in the WAL, and must come back out of the backup.
  test "a live WAL database round-trips through the backup with its newest rows" do
    Dir.mktmpdir do |tmp|
      source = File.join(tmp, "app", "storage", "production.sqlite3")
      FileUtils.mkdir_p(File.dirname(source))
      sqlite!(source, "PRAGMA journal_mode=WAL; CREATE TABLE songs(id INTEGER); " \
                      "INSERT INTO songs VALUES (1),(2),(3);")
      assert_path_exists "#{source}-wal", "the fixture must actually be in WAL mode"

      with_run(tmp: tmp, apps: [ app(tmp, "app") ]) do |backup, dir|
        entry = backup.entries_of_kind("sqlite").sole
        assert_equal File.realpath(source), entry[:source]

        copy = File.join(tmp, "restored.sqlite3")
        system("gzip", "-dc", File.join(dir, entry[:path]), out: copy, exception: true)
        assert_equal "3", sqlite!(copy, "SELECT COUNT(*) FROM songs").strip
      end
    end
  end

  # Five apps have a file called production_queue.sqlite3; a basename-keyed
  # scheme would keep one of them and silently drop four.
  test "sqlite files from different apps cannot collide in the backup" do
    one = BackupRunner.slug("/var/www/vhosts/ltvb.nl/git.ltvb.nl/storage/production_queue.sqlite3")
    two = BackupRunner.slug("/var/www/vhosts/ltvb.nl/mail.ltvb.nl/storage/production_queue.sqlite3")

    assert_not_equal one, two
    assert_equal "ltvb.nl-git.ltvb.nl-storage-production_queue.sqlite3", one
  end

  # ---- app files -----------------------------------------------------------

  test "the file archive takes the secrets and the uploads and leaves the build behind" do
    Dir.mktmpdir do |tmp|
      root = File.join(tmp, "app")
      write(root, ".env", "SECRET=1")
      write(root, "config/master.key", "deadbeef")
      write(root, "storage/uploads/photo.jpg", "jpeg")
      write(root, "storage/production.sqlite3", "not a real db")
      write(root, "storage/production.sqlite3-wal", "nor is this")
      write(root, "storage/tmp/cache.bin", "rebuildable")
      write(root, "vendor/bundle/rails.gem", "x" * 100)
      write(root, "node_modules/left-pad/index.js", "x")
      write(root, "log/production.log", "noisy")

      with_run(tmp: tmp, apps: [ app(tmp, "app") ]) do |backup, dir|
        entry = backup.entries_of_kind("files").sole
        # The first defence is the include list: vendor/, node_modules/ and log/
        # are never named, so no exclude pattern has to catch them.
        assert_equal %w[.env config/master.key storage], entry[:detail][:entries]

        listed = tar_contents(File.join(dir, entry[:path]))
        assert_includes listed, ".env"
        assert_includes listed, "config/master.key"
        assert_includes listed, "storage/uploads/photo.jpg"
        assert_empty listed.grep(/vendor|node_modules|\.log\z/), "build artefacts and logs must stay out"
        assert_empty listed.grep(%r{storage/tmp}), "rebuildable caches must stay out"
        # The SQLite phase owns these; tarring a live WAL database is exactly
        # the copy this class refuses to make.
        assert_empty listed.grep(/sqlite3/)
      end
    end
  end

  test "tar refuses to archive an empty entry list" do
    assert_raises(BackupRunner::Unsafe) { BackupRunner.tar_argv("/tmp/x.tar.gz", chdir: "/tmp", entries: []) }
  end

  # `storage` is in RUBY_APP_FILES and one app's storage is 6.3 GB of mp3 that
  # gzip cannot compress (measured ratio 0.996) plus a re-downloadable model
  # cache. Left in, a run is ~6.9 GB and 17 retained runs are ~118 GB on the
  # same disk as the data they protect.
  test "an app's excluded storage stays out of the tar and is recorded as an exclusion" do
    Dir.mktmpdir do |tmp|
      root = File.join(tmp, "music.ltvb.nl")
      write(root, ".env", "SECRET=1")
      write(root, "storage/audio/QMKHM1600218.mp3", "x" * 64)
      write(root, "storage/kokoro/model.safetensors", "y" * 64)
      write(root, "storage/uploads/cover.jpg", "jpeg")

      with_run(tmp: tmp, apps: [ app(tmp, "music.ltvb.nl") ]) do |backup, dir|
        entry  = backup.entries_of_kind("files").sole
        listed = tar_contents(File.join(dir, entry[:path]))

        assert_includes listed, "storage/uploads/cover.jpg", "the rest of storage is still backed up"
        assert_empty listed.grep(%r{storage/audio}), "6.3 GB of mp3 must not be in every nightly run"
        assert_empty listed.grep(%r{storage/kokoro})

        # Same rule as the MariaDB exclusion: named target, written reason, on
        # the row and in the manifest. An omission nobody is told about is the
        # one thing this class refuses to produce.
        excluded = backup.exclusion_entries
        assert_equal %w[music.ltvb.nl:storage/audio music.ltvb.nl:storage/kokoro],
                     excluded.map { |row| row[:target] }
        assert_match(/0\.996/, excluded.first[:reason])
        # The audio is excluded, not protected elsewhere, and the reason has to
        # say so — otherwise this reads as a solved problem.
        assert_match(/off this box/, excluded.first[:reason])
        assert_equal %w[storage/audio storage/kokoro], entry[:detail][:excludes]
        assert_match(/storage\/audio/, backup.exclusion_summary.first)

        manifest = JSON.parse(File.read(File.join(dir, "manifest.json")))
        assert_includes manifest["exclusions"].map { |row| row["target"] }, "music.ltvb.nl:storage/audio"
      end
    end
  end

  test "an app with no exclusion policy excludes nothing" do
    assert_empty BackupRunner.file_exclusions_for("git.ltvb.nl")
    assert_empty BackupRunner.excluded_paths_for("git.ltvb.nl")
  end

  # Both file walks enumerate App ROWS, so a checkout nobody registered is
  # simply absent from the manifest — the run gets smaller and says nothing.
  test "a checkout with no App row makes the run partial rather than shrinking it quietly" do
    Dir.mktmpdir do |tmp|
      registered = app(tmp, "ltvb.nl/apps.ltvb.nl")
      write(File.join(tmp, "ltvb.nl/apps.ltvb.nl"), ".env", "SECRET=1")
      write(File.join(tmp, "ltvb.nl/forgotten.ltvb.nl"), ".env", "SECRET=2")

      with_run(tmp: tmp, apps: [ registered ], vhosts_root: tmp) do |backup, _dir|
        assert_equal Backup::PARTIAL, backup.status
        assert_match(/forgotten\.ltvb\.nl.*no App row/, backup.error)
        assert_no_match(/apps\.ltvb\.nl.*no App row/, backup.error)
      end
    end
  end

  # ---- permissions ---------------------------------------------------------

  # What lands in here: the MariaDB grant tables, the psa database, every app's
  # .env and config/master.key, and tarballs of /etc/postfix and /etc/dovecot
  # holding TLS private keys that are root-only where they live. Root's umask on
  # this box is 0022, and six webspace uids plus www-data share the machine.
  test "the backup tree is 0700 and every file in it 0600" do
    with_run(schemas: { "music" => { "songs" => 2 } }) do |backup, dir|
      assert_equal 0o700, File.stat(dir).mode & 0o777
      %w[mysql sqlite files system].each do |sub|
        assert_equal 0o700, File.stat(File.join(dir, sub)).mode & 0o777, "#{sub} is not 0700"
      end

      backup.manifest_entries.each do |entry|
        path = File.join(dir, entry[:path])
        assert_equal 0o600, File.stat(path).mode & 0o777, "#{entry[:path]} is not 0600"
      end
      assert_equal 0o600, File.stat(File.join(dir, "manifest.json")).mode & 0o777
    end
  end

  test "the run puts the process umask back when it is done" do
    before = File.umask

    with_run(schemas: { "music" => { "songs" => 1 } }) { |_backup, _dir| }

    assert_equal before, File.umask, "a process left at 0077 makes unreadable files for whatever runs next"
  end

  # ---- what a restore cannot rebuild ---------------------------------------

  test "the four things no restore can reconstruct are in the system paths" do
    # Maildirs (144 MB of real mail, and this box is MX for three domains),
    # every certificate and its key, the DKIM private keys, and the psa secret
    # without which psa.accounts restores as noise.
    %w[/var/qmail/mailnames /etc/letsencrypt /etc/domainkeys /etc/psa].each do |path|
      assert_includes BackupRunner::SYSTEM_PATHS, path
    end
  end

  # ---- manifest ------------------------------------------------------------

  test "the manifest carries a size and a sha256 for every file it lists" do
    with_run(schemas: { "music" => { "songs" => 2 } }) do |backup, dir|
      assert_equal backup.item_count, backup.manifest_entries.size
      assert_operator backup.item_count, :>, 0

      backup.manifest_entries.each do |entry|
        path = File.join(dir, entry[:path])
        assert_path_exists path
        # Relative, because a manifest hard-coding today's mount point is
        # useless the moment the backup is moved off this disk.
        assert_not entry[:path].start_with?("/")
        assert_equal File.size(path), entry[:bytes]
        assert_equal Digest::SHA256.file(path).hexdigest, entry[:sha256]
      end

      assert_equal backup.manifest_entries.sum { |entry| entry[:bytes] }, backup.size_bytes
    end
  end

  # ---- verification --------------------------------------------------------

  test "a run restores one dump into a scratch database and drops it again" do
    shell = nil
    with_run(schemas: { "music" => { "songs" => 2, "albums" => 1 } }) do |backup, _dir, used|
      shell = used
      assert backup.verified?, backup.verify_detail
      assert_equal "music", backup.verify_database
      assert_equal 2, backup.verify_tables
      assert_equal 3, backup.verify_rows
      assert_not_nil backup.verified_at
    end

    assert_equal 1, shell.created.size
    assert_match BackupRunner::SCRATCH_NAME, shell.created.sole
    assert_equal shell.created, shell.dropped, "the scratch database must always be dropped"
  end

  test "a restore that loses a table fails verification instead of passing quietly" do
    with_run(schemas: { "music" => { "songs" => 2, "albums" => 1 } },
             shell_options: { corrupt_restore: "albums" }) do |backup, _dir, shell|
      assert_not backup.verified?
      assert_equal Backup::VERIFY_FAILED, backup.verify_status
      assert_match(/missing tables: albums/, backup.verify_detail)
      # Still dropped: a failed verification must not leave a scratch database
      # behind for the next run to trip over.
      assert_equal shell.created, shell.dropped
    end
  end

  # Verification compares against the counts captured AT DUMP TIME, not against
  # the live database — gitub_gui takes webhooks continuously, and comparing
  # with live counts would fail every run for a reason that is not a fault.
  test "the excluded table is expected empty and a passing run says so" do
    schemas = { "gitub_gui" => { "commits" => 3, "incoming_webhooks" => 896_776 } }

    with_run(schemas: schemas) do |backup, _dir|
      assert backup.verified?, backup.verify_detail
      assert_match(/incoming_webhooks restored empty by policy/, backup.verify_detail)
      # The row count recorded is the one that was dumped: 3 commits, and zero
      # for the table the policy left out.
      assert_equal 3, backup.verify_rows
    end
  end

  # On this server the smallest full dump is opendmarc: 1,480 bytes, 9 base
  # tables, COUNT(*) of zero in every one. Smallest-by-bytes alone restores it
  # every night, compares 0 against 0 and records "passed" having moved no data
  # at all — a truncated gzip member or a broken --hex-blob round trip in the
  # database that matters would sail through that.
  test "an empty database is never the verification sample, however small its dump is" do
    schemas = { "opendmarc" => { "messages" => 0, "domains" => 0, "reporters" => 0 },
                "music" => { "songs" => 2 } }

    with_run(schemas: schemas) do |backup, _dir|
      assert backup.verified?, backup.verify_detail
      assert_equal "music", backup.verify_database
      assert_operator backup.verify_rows, :>, 0, "a verification that moved no rows is not evidence"
    end
  end

  test "a run holding nothing but empty databases records skipped, never passed" do
    with_run(schemas: { "opendmarc" => { "messages" => 0, "domains" => 0 } }) do |backup, _dir|
      assert_equal Backup::VERIFY_SKIPPED, backup.verify_status
      assert_not backup.verified?
      assert_match(/no full mysql dump with any rows/, backup.verify_detail)
    end
  end

  test "an explicitly named empty database is restored but not called proof" do
    with_run(schemas: { "opendmarc" => { "messages" => 0 } }, verify: false) do |backup, _dir, shell|
      BackupRunner.for(backup, shell: shell, databases: [ "opendmarc" ]).verify!(database: "opendmarc")

      assert_equal Backup::VERIFY_SKIPPED, backup.reload.verify_status
      assert_match(/0 == 0 is not evidence/, backup.verify_detail)
      # Still restored and still cleaned up: the operator asked, and the answer
      # is about the evidence, not about refusing to look.
      assert_equal shell.created, shell.dropped
      assert_equal [ [ "opendmarc", shell.created.sole ] ], shell.restores
    end
  end

  test "verification is skipped explicitly, never left looking like it passed" do
    with_run(schemas: { "music" => { "songs" => 1 } }, verify: false) do |backup, _dir|
      assert_equal Backup::VERIFY_SKIPPED, backup.verify_status
      assert_not backup.verified?
      assert_nil backup.verified_at
    end
  end

  test "counts are compared table by table" do
    same = BackupRunner.compare_counts(expected: { "a" => 2, "b" => 0 }, restored: { "a" => 2, "b" => 0 })
    assert same.ok?
    assert_equal 2, same.tables
    assert_equal 2, same.rows

    short = BackupRunner.compare_counts(expected: { "a" => 3 }, restored: { "a" => 2 })
    assert_not short.ok?
    assert_match(/a expected 3, restored 2/, short.detail)

    missing = BackupRunner.compare_counts(expected: { "a" => 1, "b" => 1 }, restored: { "a" => 1 })
    assert_not missing.ok?
    assert_equal [ "b" ], missing.missing

    # An unexpected table means the scratch database was not clean, which makes
    # every other number in the comparison meaningless.
    extra = BackupRunner.compare_counts(expected: { "a" => 1 }, restored: { "a" => 1, "leftover" => 4 })
    assert_not extra.ok?
    assert_equal [ "leftover" ], extra.extra
  end

  # Row counts come from COUNT(*), never from information_schema.table_rows,
  # which is an InnoDB estimate and cannot be compared against anything.
  test "count queries name the schema and the table as quoted identifiers" do
    sql = BackupRunner.count_query("email.lucasvanbriemen.nl", %w[messages threads])

    assert_equal "SELECT 'messages', COUNT(*) FROM `email.lucasvanbriemen.nl`.`messages` UNION ALL " \
                 "SELECT 'threads', COUNT(*) FROM `email.lucasvanbriemen.nl`.`threads`", sql
    assert_raises(BackupRunner::Unsafe) { BackupRunner.count_query("music", [ "songs`; DROP" ]) }
  end

  # DROP DATABASE is the most destructive statement in the whole service, so the
  # name is checked when it is minted and again immediately before the drop.
  test "the scratch database name is generated and cannot be anything else" do
    assert_match BackupRunner::SCRATCH_NAME, BackupRunner.scratch_name
    assert_raises(BackupRunner::Unsafe) { BackupRunner.scratch_name(random: "psa") }

    runner = BackupRunner.new(root: "/tmp", databases: [], shell: FakeMysql.new)
    assert_raises(BackupRunner::Unsafe) { runner.send(:drop_scratch!, "psa") }
    assert_raises(BackupRunner::Unsafe) { runner.send(:drop_scratch!, "ltvb_verify_psa") }
  end

  test "a pre-existing scratch database is left alone rather than reused" do
    collision = "ltvb_verify_0000000000000000"

    with_run(schemas: { "music" => { "songs" => 1 } }, verify: false) do |backup, _dir, shell|
      shell.plant(collision)
      BackupRunner.for(backup, shell: shell, databases: [ "music" ]).verify!(scratch: collision)

      assert_equal Backup::VERIFY_FAILED, backup.reload.verify_status
      assert_match(/already exists/, backup.verify_detail)
      assert_empty shell.dropped, "an existing database must not be dropped by a verification"
    end
  end

  test "a scratch name that is not one is refused before any SQL is sent" do
    # A manifest entry exactly as dump_databases! writes one: every mysql item
    # carries its mode and the COUNT(*) per table it was dumped with.
    backup = Backup.create!(path: "/tmp/20260815T180000Z", status: Backup::SUCCEEDED,
                            started_at: Time.utc(2026, 8, 15, 18),
                            manifest: [ { kind: "mysql", source: "music", path: "mysql/music.sql.gz",
                                          bytes: 1, detail: { mode: "full", table_rows: { songs: 1 } } } ])
    shell = FakeMysql.new(schemas: { "music" => { "songs" => 1 } })

    BackupRunner.for(backup, shell: shell).verify!(scratch: "psa")

    assert_equal Backup::VERIFY_FAILED, backup.reload.verify_status
    assert_match(/refusing "psa"/, backup.verify_detail)
    assert_empty shell.created
    assert_empty shell.dropped
  end

  # ---- partial runs --------------------------------------------------------

  # An unreadable /etc/postfix must not be silent, and must not throw away the
  # database dumps that did work either. That is what PARTIAL is for.
  test "a missing system config path makes the run partial and names what is absent" do
    with_run(schemas: { "music" => { "songs" => 1 } },
             system_paths: [ "/nonexistent/etc/postfix" ]) do |backup, _dir|
      assert_equal Backup::PARTIAL, backup.status
      assert_match(%r{/nonexistent/etc/postfix}, backup.error)
      assert_equal 1, backup.entries_of_kind("mysql").size, "the dumps that worked are still kept"
    end
  end

  test "system config is archived per path" do
    Dir.mktmpdir do |tmp|
      etc = File.join(tmp, "etc-ltvb")
      write(etc, "nginx/sites/git.conf", "server {}")

      with_run(tmp: tmp, system_paths: [ etc ]) do |backup, dir|
        entry = backup.entries_of_kind("system").sole
        assert_equal etc, entry[:source]
        assert_includes tar_contents(File.join(dir, entry[:path])), "etc-ltvb/nginx/sites/git.conf"
      end
    end
  end

  # ---- retention -----------------------------------------------------------

  test "retention keeps the newest run in each recent day, week and month" do
    now = Time.utc(2026, 8, 15, 12, 0, 0)
    # One run a day for 40 days, plus an earlier second run on the newest day.
    daily  = (0..39).map { |days| backup_row(now - days.days) }
    second = backup_row(now - 3.hours)

    kept = Backup.keep_ids((daily + [ second ]).shuffle, now: now)
    kept_times = (daily + [ second ]).select { |backup| kept.include?(backup.id) }
                                     .map(&:started_at).sort.reverse

    # The newest run in each of the seven most recent days that has one.
    assert_equal((0..6).map { |days| now - days.days }, kept_times.first(7))
    assert_not_includes kept_times, second.started_at,
                        "only the newest run in a day holds that day's slot"

    # Then ISO weeks and months, reaching back past the dailies rather than
    # duplicating them, and never more slots than the policy allows.
    assert_operator kept_times.size, :<=, Backup::RETENTION.values.sum
    assert_operator kept_times.size, :>, Backup::RETENTION[:daily]
    assert_operator kept_times.last, :<, now - 7.days
  end

  # Retention must never eat the only backup anybody has proof about — the same
  # rule, and the same reasoning, as Release.protected_ids keeping the rollback
  # target alive past `keep`.
  test "the newest verified backup survives retention however old it is" do
    now = Time.utc(2026, 8, 15)
    old = backup_row(now - 300.days, verify_status: Backup::VERIFY_PASSED)
    recent = (0..9).map { |days| backup_row(now - days.days) }

    kept = Backup.keep_ids(recent + [ old ], now: now)
    assert_includes kept, old.id
  end

  test "a running backup is never pruned and a failed one is not protected" do
    now = Time.utc(2026, 8, 15)
    running = backup_row(now, status: Backup::RUNNING)
    failed  = backup_row(now - 200.days, status: Backup::FAILED)
    dailies = (1..9).map { |days| backup_row(now - days.days) }

    kept = Backup.keep_ids(dailies + [ running, failed ], now: now)
    assert_includes kept, running.id
    assert_not_includes kept, failed.id
  end

  # A row dated in the future would hold the newest daily slot forever and push
  # a real backup out of the window — but deleting a directory whose timestamp
  # we cannot explain is guessing, not retention.
  test "a backup timestamped in the future is kept but takes no retention slot" do
    now = Time.utc(2026, 8, 15)
    future = backup_row(now + 5.days)
    dailies = (0..9).map { |days| backup_row(now - days.days) }

    kept = Backup.keep_ids(dailies + [ future ], now: now)
    assert_includes kept, future.id
    assert_equal 7, dailies.count { |backup| kept.include?(backup.id) }
  end

  # The nightly timer will miss nights — a reboot, a full disk, a bad deploy.
  # A policy phrased as "delete anything older than seven days" would turn a
  # fortnight of missed runs into no backups at all.
  test "a gap in the schedule does not delete the last good backup" do
    now = Time.utc(2026, 8, 15)
    stale = backup_row(now - 45.days)

    assert_includes Backup.keep_ids([ stale ], now: now), stale.id
  end

  test "prune deletes the directory and keeps the row" do
    Dir.mktmpdir do |tmp|
      # Two runs on one day: the newer holds that day's, that week's and that
      # month's slot, so the earlier is the first thing retention releases.
      superseded = Backup.create!(path: File.join(tmp, "20260815T020000Z"), status: Backup::SUCCEEDED,
                                  started_at: Time.utc(2026, 8, 15, 2))
      keep = Backup.create!(path: File.join(tmp, "20260815T120000Z"), status: Backup::SUCCEEDED,
                            started_at: Time.utc(2026, 8, 15, 12))
      [ superseded, keep ].each { |backup| FileUtils.mkdir_p(backup.path) }

      runner = BackupRunner.new(root: tmp, databases: [], shell: FakeMysql.new)
      pruned = runner.prune!(now: Time.utc(2026, 8, 15, 13))

      assert_equal [ superseded.id ], pruned.map(&:id)
      assert_not File.exist?(superseded.path)
      assert_path_exists keep.path
      assert superseded.reload.pruned?, "the row outlives the bytes"
      assert_equal Backup::SUCCEEDED, superseded.status
    end
  end

  # `on_disk` (pruned_at IS NULL) is a claim about the row; `on_disk?` is a
  # question about the disk. While they disagree, a row whose directory is gone
  # holds the "newest usable" and "newest verified" protections on behalf of
  # bytes that do not exist — and real directories get deleted to make room for
  # the memory of one that is not there.
  test "a row whose directory vanished protects nothing and is recorded as pruned" do
    Dir.mktmpdir do |tmp|
      now = Time.utc(2026, 8, 15, 12)
      ghost = disk_backup(tmp, now - 3.hours, on_disk: false,
                          verify_status: Backup::VERIFY_PASSED, verified_at: now - 3.hours)
      dailies = (1..12).map { |days| disk_backup(tmp, now - days.days) }

      assert_not ghost.on_disk?, "the fixture must have no directory"

      runner = BackupRunner.new(root: tmp, databases: [], shell: FakeMysql.new)
      pruned = runner.prune!(now: now)

      assert_not_includes pruned.map(&:id), ghost.id
      assert ghost.reload.pruned?, "the row outlives the bytes, but it stops protecting them"
      # The newest run that actually exists is protected, and so is one per day
      # for the seven most recent days that have one — the ghost holds neither
      # the "newest verified" slot nor a daily one.
      assert_path_exists dailies.first.path
      assert_equal 7, dailies.count { |backup| Dir.exist?(backup.path) }
      assert_equal 5, pruned.size
    end
  end

  test "a killed run stops protecting its directory once it cannot still be running" do
    now     = Time.utc(2026, 8, 15, 12)
    running = backup_row(now - 1.hour, status: Backup::RUNNING)
    killed  = backup_row(now - 3.days, status: Backup::RUNNING)

    kept = Backup.keep_ids([ running, killed ], now: now)
    assert_includes kept, running.id, "a run in flight is being written to"
    assert_not_includes kept, killed.id

    Backup.abandon_stale_runs!(now: now)
    assert_equal Backup::FAILED, killed.reload.status
    assert_match(/abandoned/, killed.error)
    assert_equal Backup::RUNNING, running.reload.status
  end

  # FileUtils.rm_rf is force-silent. Recording a prune that did not happen would
  # hide the row behind the `on_disk` scope for good, while the bytes stayed.
  test "a delete that did not happen is not recorded as a prune" do
    skip "root ignores the read-only parent this fixture depends on" if Process.uid.zero?

    Dir.mktmpdir do |tmp|
      now = Time.utc(2026, 8, 15, 13)
      superseded = disk_backup(tmp, Time.utc(2026, 8, 15, 2))
      keep       = disk_backup(tmp, Time.utc(2026, 8, 15, 12))
      runner     = BackupRunner.new(root: tmp, databases: [], shell: FakeMysql.new)

      begin
        FileUtils.chmod(0o500, tmp)
        pruned = runner.prune!(now: now)

        assert_empty pruned.map(&:id)
        assert_not superseded.reload.pruned?, "the next prune has to be able to retry it"
        assert_match(/could not be deleted/, runner.problems.sole)
      ensure
        FileUtils.chmod(0o700, tmp)
      end

      assert_path_exists superseded.path
      assert_path_exists keep.path
    end
  end

  test "a directory with no row is reported, never deleted" do
    Dir.mktmpdir do |tmp|
      orphan = File.join(tmp, "20260101T000000Z")
      FileUtils.mkdir_p(orphan)
      FileUtils.mkdir_p(File.join(tmp, "not-a-backup"))
      runner = BackupRunner.new(root: tmp, databases: [], shell: FakeMysql.new)

      assert_equal [ orphan ], runner.orphan_directories
      runner.prune!(now: Time.utc(2026, 8, 15))

      # The manager's own SQLite database is inside the backup, so after a
      # restore of it every newer directory is an orphan — a sweep would delete
      # the newest backups first.
      assert_path_exists orphan
    end
  end

  test "a missing backup root is not an instruction to forget every backup" do
    row = Backup.create!(path: "/nonexistent/ltvb/20260815T020000Z", status: Backup::SUCCEEDED,
                         started_at: Time.utc(2026, 8, 15, 2))
    runner = BackupRunner.new(root: "/nonexistent/ltvb", databases: [], shell: FakeMysql.new)

    assert_empty runner.prune!(now: Time.utc(2026, 8, 15, 13))
    assert_not row.reload.pruned?, "an unmounted disk must not rewrite the history"
    assert_match(/does not exist/, runner.problems.sole)
  end

  test "verification going stale is a state something can act on" do
    now = Time.utc(2026, 8, 15, 12)
    assert Backup.verification_overdue?(now: now), "never proven must not read as fine"
    assert_match(/NO backup has ever been proven/, Backup.verification_summary(now: now))

    fresh = backup_row(now - 2.hours, verify_status: Backup::VERIFY_PASSED)
    fresh.update!(verified_at: now - 2.hours, verify_database: "music", verify_tables: 2, verify_rows: 3)

    assert_not Backup.verification_overdue?(now: now)
    assert_match(/last proven restorable 2h ago: music/, Backup.verification_summary(now: now))

    fresh.update!(verified_at: now - 40.hours)
    assert Backup.verification_overdue?(now: now)
    assert_match(/OVERDUE/, Backup.verification_summary(now: now))
  end

  # rm -rf under a directory this class generates is still rm -rf.
  test "prune refuses a path that is not a direct child of the backup root" do
    runner = BackupRunner.new(root: "/var/backups/ltvb", databases: [], shell: FakeMysql.new)

    [ "/var/www/vhosts/ltvb.nl", "/var/backups/ltvb", "/var/backups/ltvb/a/b" ].each do |path|
      assert_raises(BackupRunner::Unsafe) { runner.send(:prunable_path!, Backup.new(path: path)) }
    end
  end

  # ---- delegation to root --------------------------------------------------

  # The manager runs as `ltvb` and can read none of the sources, so the plan is
  # what crosses to root — typed, never a command line, for the same reason
  # Agent gives about nginx config.
  test "the plan hands root a typed spec rather than a command" do
    runner = BackupRunner.new(root: "/var/backups/ltvb", now: Time.utc(2026, 8, 15, 18),
                              databases: %w[gitub_gui music], apps: [], system_paths: [],
                              defaults_file: DEFAULTS)
    params = runner.plan.to_params

    assert_equal "20260815T180000Z", params[:stamp]
    assert_equal({ name: "gitub_gui", mode: "exclude_tables", exclude_tables: [ "incoming_webhooks" ] },
                 params[:databases].first)
    assert_equal({ name: "music", mode: "full", exclude_tables: [] }, params[:databases].last)
    # Nothing in the payload is a string root would execute.
    assert_empty params.to_s.scan(/mysqldump|tar |sqlite3|;|\|/)
  end

  # The plan is built by the manager (uid 10006), which can read neither
  # candidate — /etc/mysql/debian.cnf is 0600 root:root and /etc/ltvb is
  # root-only. A readability probe there always answers "no", so the project's
  # own credentials file could never be selected however long ago it was
  # installed. The plan therefore carries intent and root resolves the fallback.
  test "the plan names the credentials file it wants, not the one this uid can read" do
    runner = BackupRunner.new(root: "/tmp", databases: [], apps: [], system_paths: [],
                              shell: FakeMysql.new)

    assert_not File.readable?(BackupRunner::DEFAULTS_FILE),
               "this assertion is vacuous on a machine where the file exists"
    assert_equal BackupRunner::DEFAULTS_FILE, runner.plan.to_params[:defaults_file]
    assert_equal BackupRunner::FALLBACK_DEFAULTS_FILE, runner.resolved_defaults_file
  end

  test "a credentials file named explicitly is used as given, never second-guessed" do
    runner = BackupRunner.new(root: "/tmp", databases: [], apps: [], system_paths: [],
                              defaults_file: "/etc/ltvb/other.cnf", shell: FakeMysql.new)

    assert_equal "/etc/ltvb/other.cnf", runner.plan.to_params[:defaults_file]
    assert_equal "/etc/ltvb/other.cnf", runner.resolved_defaults_file
  end

  private

  # An App whose files live under a temp directory, the same trick
  # ReleaseLayoutTest uses to exercise real filesystem behaviour.
  def app(tmp, dir, app_kind: "rails")
    record = App.new(name: dir, app_kind: app_kind, subdomain: dir, domain: "ltvb.nl",
                     ruby_version: "3.3.8", git_repo_url: "git@github.com:x/y.git",
                     primary_db_kind: "sqlite", doc_root_suffix: "public")
    path = File.join(tmp, dir)
    record.define_singleton_method(:app_path) { path }
    record
  end

  # Runs a whole backup into a temp root with MariaDB simulated and everything
  # else real, then yields the row, the directory and the shell.
  def with_run(schemas: {}, apps: [], system_paths: [], tmp: nil, verify: true,
               shell_options: {}, vhosts_root: nil, &block)
    if tmp.nil?
      return Dir.mktmpdir do |dir|
        with_run(schemas: schemas, apps: apps, system_paths: system_paths, tmp: dir,
                 verify: verify, shell_options: shell_options, vhosts_root: vhosts_root, &block)
      end
    end

    shell = FakeMysql.new(schemas: schemas.deep_dup, **shell_options)
    runner = BackupRunner.new(root: File.join(tmp, "backups"), now: Time.utc(2026, 8, 15, 18),
                              apps: apps, system_paths: system_paths, shell: shell,
                              verify: verify, defaults_file: DEFAULTS, host: "test",
                              # Nothing on a laptop, which is what the walk for
                              # unregistered checkouts should find by default.
                              vhosts_root: vhosts_root || File.join(tmp, "no-vhosts"))
    backup = runner.call
    block.call(backup, runner.directory, shell)
  end

  def backup_row(started_at, status: Backup::SUCCEEDED, verify_status: Backup::VERIFY_PENDING)
    Backup.create!(path: "/var/backups/ltvb/#{started_at.utc.strftime('%Y%m%dT%H%M%S%LZ')}",
                   status: status, started_at: started_at, verify_status: verify_status)
  end

  # A row AND its directory, so retention can be exercised against what is
  # actually on the disk rather than against the row alone. `on_disk: false`
  # builds the row without the directory — the ghost this class has to survive.
  def disk_backup(root, started_at, on_disk: true, status: Backup::SUCCEEDED, **attributes)
    path = File.join(root, started_at.utc.strftime(BackupRunner::STAMP_FORMAT))
    FileUtils.mkdir_p(path) if on_disk
    Backup.create!(path: path, status: status, started_at: started_at, **attributes)
  end

  def write(root, relative, contents)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  def sqlite!(path, sql)
    out, err, status = Open3.capture3("sqlite3", path, sql)
    raise "sqlite3 #{path}: #{err}" unless status.success?

    out
  end

  def tar_contents(archive)
    out, err, status = Open3.capture3("tar", "-tzf", archive)
    raise "tar -tzf #{archive}: #{err}" unless status.success?

    out.lines.map(&:chomp)
  end
end
