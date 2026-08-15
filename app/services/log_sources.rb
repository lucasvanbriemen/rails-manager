require "open3"

# Every log a managed app can produce, whatever its runtime: the app's own
# log/ or storage/logs/, the web server (nginx now, Apache while the vhosts are
# still Plesk's), the PHP-FPM pool, the systemd units the manager installs, and
# supervisor program output. Replaces LogFiles, which only knew about Rails.
#
# Two properties carried over from LogFiles and worth keeping:
#
#   * Every path comes from a fixed set of roots derived from the App record.
#     A user-supplied source id is only ever MATCHED against the discovered
#     list (see .find), never used to build a path — so "../../etc/shadow" is
#     a 404, not a file read.
#   * Paths that come out of a config file on disk (a pool's error_log, a
#     supervisor program's stdout_logfile) are re-checked against those roots
#     before being offered. Those files are root-owned, but a mistake in one
#     must not widen what the manager will hand to a browser.
#
# Reads are incremental. `read` takes the caller's byte offset (files) or
# journald cursor (units) and returns only what arrived since, plus the
# position to send next time — so following a 400 MB production.log costs one
# seek per poll instead of re-shipping the whole tail every two seconds.
#
# As in SystemStats, the parsing is split from the reading (each parse_* takes
# text, and roots/within_roots? are public) because none of these directories
# exist off-server — that split is what makes the rules testable.
module LogSources
  LINE_CHOICES = [ 200, 1000, 5000 ].freeze
  DEFAULT_ID   = "rails:production.log".freeze

  # Bytes read per requested line when tailing. production.log lines run long
  # (SQL, params), so budget generously — the tail still keeps only N lines.
  BYTES_PER_LINE = 400

  # Ceiling on one incremental response. A deploy or an exception storm can
  # append tens of MB between two polls; past this we skip forward instead of
  # making the browser page through history it will never scroll back to.
  MAX_CHUNK_BYTES = 2_000_000

  # Where the manager's own nginx/PHP-FPM configs write: one directory per
  # hostname, group-readable by ltvb-log (root writes, the manager reads).
  SITE_LOG_ROOT       = "/var/log/ltvb/sites".freeze
  SUPERVISOR_CONF_DIR = "/etc/supervisor/conf.d".freeze
  SUPERVISOR_LOG_ROOT = "/var/log/supervisor".freeze

  # Journald cursors round-trip through the browser, so they come back
  # untrusted. A cursor can't inject an argument (argv, not a shell string),
  # but a malformed one should be dropped rather than handed to journalctl.
  CURSOR_FORMAT = /\A[a-zA-Z0-9;:=_.\/+-]{1,512}\z/

  HOSTNAME_FORMAT    = /\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?\z/
  PHP_VERSION_FORMAT = /\A\d+\.\d+\z/
  # The charset systemd allows in a unit name; guards the journalctl argv.
  UNIT_FORMAT = /\A[a-zA-Z0-9@._-]+\z/

  # `path` is set for files, `unit` for journald. `size`/`mtime` are nil on a
  # journal source — the UI shows a dash rather than a wrong number.
  Source = Struct.new(:id, :label, :group, :path, :unit, :size, :mtime, keyword_init: true) do
    def journal? = unit.present?
    def file?    = path.present?
  end

  # One incremental read:
  #   content    — the new text, whole lines only
  #   next_byte  — offset to send as from_byte on the next poll (files)
  #   cursor     — cursor to send on the next poll (journal)
  #   reset      — the file shrank (rotated/truncated); content is a fresh tail
  #   truncated  — more than MAX_CHUNK_BYTES was pending, so we skipped forward
  Chunk = Struct.new(:content, :next_byte, :cursor, :size, :reset, :truncated, keyword_init: true)

  class << self
    def for(app)
      sources = app_log_sources(app) + site_log_sources(app) + apache_log_sources(app) +
                php_fpm_sources(app) + journal_sources(app) + supervisor_sources(app)
      # A supervisor program often logs straight into the app's own log/ dir,
      # so the same file gets discovered twice under two different groups.
      sources.uniq { |s| [ s.path, s.unit ] }
    end

    # The ONLY way a request-supplied id becomes a path: by matching one that
    # discovery already produced.
    def find(app, id)
      self.for(app).find { |s| s.id == id }
    end

    def default(app)
      sources = self.for(app)
      preferred_ids(app).lazy.filter_map { |id| sources.find { |s| s.id == id } }.first || sources.first
    end

    # Incremental read of one source. Pass the previous chunk's next_byte /
    # cursor to get only what has been written since; pass neither for a tail.
    def read(source, from_byte: nil, cursor: nil, lines: 200)
      return journal_chunk(source, cursor: cursor, lines: lines) if source.journal?

      file_chunk(source.path, from_byte: from_byte, lines: lines)
    end

    # ---- the path rule -----------------------------------------------------

    # The roots a path must live under to be offered at all, derived entirely
    # from the App record. A record with a blank subdomain/domain contributes
    # nothing: its fqdn is "." and File.join would otherwise resolve
    # /var/log/ltvb/sites/. — i.e. every site's logs — into the allowed set.
    # Same class of bug that App#undeployable_reason guards against.
    def roots(app)
      paths = [ app.app_path, SUPERVISOR_LOG_ROOT ]
      paths << File.join(app.webspace_root, "logs") if app.domain.present?
      paths << site_log_dir(app)
      paths.compact.map { |p| File.expand_path(p) }
    end

    def within_roots?(path, app)
      full = File.expand_path(path)
      roots(app).any? { |root| full == root || full.start_with?("#{root}/") }
    end

    # ---- discovery ---------------------------------------------------------

    # The app's own logs. Rails writes log/*.log; Laravel (and the cron-only
    # Laravel apps) write storage/logs/*.log.
    def app_log_sources(app)
      globs = []
      globs << [ "rails", File.join(app.app_path, "log", "*.log") ] if app.ruby? || app.repo?
      globs << [ "laravel", File.join(app.app_path, "storage", "logs", "*.log") ] if app.php?

      globs.flat_map do |group, glob|
        Dir.glob(glob).sort.filter_map { |path| file_source(group, path, app) }
      end
    end

    # /var/log/ltvb/sites/<fqdn>/ holds everything the manager configures for
    # that hostname: nginx access/error, plus the PHP-FPM pool log for apps
    # that have one. Grouped by filename so the UI can label them.
    def site_log_sources(app)
      dir = site_log_dir(app)
      return [] unless dir

      Dir.glob(File.join(dir, "*.log")).sort.filter_map do |path|
        group = File.basename(path).start_with?("php-fpm") ? "php-fpm" : "nginx"
        file_source(group, path, app)
      end
    end

    # Apache's per-vhost logs, for as long as Plesk still generates the vhosts.
    # Plesk's live logs are extensionless (access_log, error_log); every dotted
    # sibling in that directory is a rotation (.1.gz) or a webstat artefact
    # (.processed, .statbuf, .webstat) that nobody wants to read.
    def apache_log_sources(app)
      return [] unless safe_hostname?(app)

      dir = File.join(app.webspace_root, "logs", app.fqdn)
      Dir.glob(File.join(dir, "*")).sort
         .reject { |path| File.basename(path).include?(".") }
         .filter_map { |path| file_source("apache", path, app) }
    end

    # The pool's own error_log, when its config names one. Plesk's generated
    # pools don't (worker output lands in the shared, root-only
    # /var/log/php8.3-fpm.log, which the manager can neither read nor scope to
    # one app), and the manager's own pools point into the site log dir that
    # site_log_sources already covers. This catches a hand-set path in
    # between — and only if it lands inside this app's roots.
    def php_fpm_sources(app)
      return [] unless app.php? && safe_hostname?(app)
      return [] unless app.php_version.to_s.match?(PHP_VERSION_FORMAT)

      text = read_config("/etc/php/#{app.php_version}/fpm/pool.d/#{app.fqdn}.conf")
      path = text && pool_error_log(text)
      path ? [ file_source("php-fpm", path, app) ].compact : []
    end

    # php_value[error_log] / php_admin_value[error_log] from a pool config.
    # Relative values are FPM-prefix-relative and deliberately ignored — a
    # guess at the prefix is how you end up reading the wrong file.
    def pool_error_log(text)
      value = text[/^\s*php_(?:admin_)?value\[error_log\]\s*=\s*(.+)$/, 1].to_s.strip.delete('"')
      value.start_with?("/") ? value : nil
    end

    def journal_sources(app)
      loaded_units(journal_units(app)).map do |unit|
        Source.new(id: "journal:#{unit}", label: "journal/#{unit}", group: "journal", unit: unit)
      end
    end

    # The app's own Puma unit plus every background worker registered for it.
    # The names come from SystemdUnit and ProcessService — the code that names
    # the files root installs — rather than from a template of our own: a unit
    # name that drifts is a log viewer that silently shows nothing.
    #
    # A worker whose unit isn't installed yet (the adopted supervisor programs)
    # is still a candidate; loaded_units drops it until it exists.
    def journal_units(app)
      units = [ puma_unit_name(app) ]
      # app_id nil would match the host-wide workers that belong to no app.
      units += ProcessService.where(app_id: app.id).pluck(:name) if app.persisted?
      units.compact.uniq.select { |u| u.match?(UNIT_FORMAT) }
    end

    # Supervisor is the source of truth for its own log paths, so read them out
    # of the program blocks instead of guessing a naming scheme. Only programs
    # whose command or working directory sits inside THIS app's checkout are
    # offered — that is what scopes the shared /var/log/supervisor to one app.
    def supervisor_sources(app)
      Dir.glob(File.join(SUPERVISOR_CONF_DIR, "*.conf")).sort.flat_map do |conf|
        text = read_config(conf)
        next [] unless text

        parse_supervisor(text).flat_map do |program, settings|
          next [] unless supervises?(settings, app.app_path)

          supervisor_file_sources(program, settings, app)
        end
      end
    end

    # program name => { key => value }. Supervisor's ini has no nesting and
    # ignores unknown keys, so a hand-rolled scan is enough — and it avoids
    # caring about the `%(program_name)s` syntax a strict ini parser chokes on.
    def parse_supervisor(text)
      programs = {}
      current  = nil
      text.to_s.each_line do |line|
        line = line.strip
        next if line.empty? || line.start_with?(";", "#")

        if (name = line[/\A\[program:([^\]]+)\]\z/, 1])
          current = programs[name] ||= {}
        elsif current && line.include?("=")
          key, value = line.split("=", 2)
          current[key.strip] = value.strip
        end
      end
      programs
    end

    # supervisor writes `directory=` and an absolute path in `command=`; either
    # one pointing into the checkout means the program belongs to this app. The
    # trailing slash keeps /…/music.ltvb.nl from matching /…/music.ltvb.nl.old.
    def supervises?(settings, app_path)
      prefix    = "#{app_path}/"
      directory = settings["directory"].to_s
      directory == app_path || directory.start_with?(prefix) ||
        settings["command"].to_s.include?(prefix)
    end

    # AUTO/NONE/syslog are supervisor's own sentinels, not paths.
    # %(program_name)s is the one expansion worth resolving; anything still
    # holding a placeholder (%(process_num)s needs the numprocs fan-out) is
    # skipped rather than guessed at.
    def supervisor_log_path(value, program)
      value = value.to_s.strip
      return nil if value.empty? || %w[AUTO NONE syslog].include?(value)

      path = value.gsub("%(program_name)s", program)
      return nil if path.include?("%(") || !path.start_with?("/")

      path
    end

    # ---- reading -----------------------------------------------------------

    def file_chunk(path, from_byte: nil, lines: 200)
      # from_byte is a String on every poll (query param) but an Integer from
      # internal callers and tests.
      from_byte = from_byte.presence&.to_i
      lines     = line_count(lines)

      File.open(path, "rb") do |f|
        size = f.size
        # An offset past EOF means the file was rotated or truncated under us.
        # Replaying from 0 would dump the whole new file into the viewer, so
        # start again from its tail and say so.
        reset = from_byte.present? && from_byte > size
        return tail_chunk(f, size, lines, reset: reset) if from_byte.blank? || reset || from_byte.negative?
        return Chunk.new(content: "", next_byte: from_byte, size: size) if from_byte == size

        incremental_chunk(f, size, from_byte)
      end
    rescue SystemCallError, IOError => e
      Chunk.new(content: "(could not read #{path}: #{e.message})", next_byte: from_byte)
    end

    # journalctl does the incremental work for us: --after-cursor replays
    # nothing, and --show-cursor hands back the position to resume from even
    # when the window turned out to be empty.
    #
    # Reading another user's unit needs the manager to be in `systemd-journal`
    # or `adm`; without that journalctl silently shows only our own messages,
    # which is why the empty case still reports a cursor rather than an error.
    def journal_chunk(source, cursor: nil, lines: 200)
      cursor = nil unless cursor.to_s.match?(CURSOR_FORMAT)
      args = [ "--unit", source.unit, "--no-pager", "--show-cursor", "--output", "short-iso" ]
      args += cursor ? [ "--after-cursor", cursor ] : [ "--lines", line_count(lines).to_s ]

      out, err, status = Open3.capture3("journalctl", *args)
      unless status&.success?
        return Chunk.new(content: "(journalctl failed: #{err.to_s.strip.presence || 'unknown error'})",
                         cursor: cursor)
      end

      text = decode(out)
      body = text.lines.reject { |l| l.start_with?("-- cursor: ") || l.strip == "-- No entries --" }
      Chunk.new(content: body.join, cursor: text[/^-- cursor: (\S+)$/, 1] || cursor)
    rescue SystemCallError, IOError => e
      Chunk.new(content: "(could not read journal for #{source.unit}: #{e.message})", cursor: cursor)
    end

    private

    def tail_chunk(f, size, lines, reset: false)
      start = [ 0, size - (lines * BYTES_PER_LINE) ].max
      f.seek(start)
      text = decode(f.read(size - start))
      # Seeking by bytes lands mid-line; drop that fragment so the first line
      # shown is a real one (last(lines) usually eats it, but not on a file of
      # fewer than `lines` very long lines).
      text = text.sub(/\A[^\n]*\n/, "") if start.positive?

      Chunk.new(content: text.lines.last(lines).join, next_byte: size, size: size, reset: reset)
    end

    def incremental_chunk(f, size, from_byte)
      start     = from_byte
      truncated = size - start > MAX_CHUNK_BYTES
      start     = size - MAX_CHUNK_BYTES if truncated
      f.seek(start)
      data = f.read(size - start).to_s

      # Ship whole lines only: the writer may have flushed half a line, and an
      # offset in the middle of one would also split a multi-byte character —
      # the remainder arrives on the next poll. Exception: a single line longer
      # than the cap would stall the viewer forever, so once we are already
      # skipping ahead, an unterminated fragment goes out as-is.
      keep = data.rindex("\n")
      keep = keep ? keep + 1 : (truncated ? data.bytesize : 0)
      text = decode(data.byteslice(0, keep))
      text = text.sub(/\A[^\n]*\n/, "") if truncated

      Chunk.new(content: text, next_byte: start + keep, size: size, truncated: truncated)
    end

    # ---- helpers -----------------------------------------------------------

    def file_source(group, path, app, id: nil, label: nil)
      return nil unless within_roots?(path, app)
      return nil unless File.file?(path) && File.readable?(path)

      stat = File.stat(path)
      Source.new(id: id || "#{group}:#{File.basename(path)}",
                 label: label || "#{group}/#{File.basename(path)}",
                 group: group, path: path, size: stat.size, mtime: stat.mtime)
    rescue SystemCallError, IOError
      nil
    end

    def supervisor_file_sources(program, settings, app)
      [ [ "stdout_logfile", "out" ], [ "stderr_logfile", "err" ] ].filter_map do |key, suffix|
        path = supervisor_log_path(settings[key], program)
        next unless path

        file_source("supervisor", path, app,
                    id: "supervisor:#{program}.#{suffix}",
                    label: "supervisor/#{program}.#{suffix}")
      end
    end

    def site_log_dir(app)
      safe_hostname?(app) ? File.join(SITE_LOG_ROOT, app.fqdn) : nil
    end

    # nil rather than a raise: an app whose hostname SystemdUnit refuses has no
    # unit installed either, so there is no journal to read.
    def puma_unit_name(app)
      return nil unless app.rails_app? && safe_hostname?(app)

      SystemdUnit.app_unit_name(app)
    rescue SystemdUnit::Unsafe
      nil
    end

    def safe_hostname?(app)
      app.subdomain.present? && app.domain.present? && app.fqdn.match?(HOSTNAME_FORMAT)
    end

    # `systemctl show --value` prints one value per unit, blank-line separated,
    # in argument order — one call for all candidates. Off-server there is no
    # systemctl, and the rescue turns that into "no journal sources" rather
    # than an exception on the logs page.
    def loaded_units(units)
      return [] if units.empty?

      out, _err, status = Open3.capture3("systemctl", "show", "--property=LoadState", "--value", *units)
      return [] unless status&.success?

      units.zip(out.split(/\n+/).map(&:strip)).filter_map { |unit, state| unit if state == "loaded" }
    rescue SystemCallError, IOError
      []
    end

    def preferred_ids(app)
      case app.app_kind
      when "rails"           then [ DEFAULT_ID, "nginx:error.log" ]
      when "laravel", "cron" then [ "laravel:laravel.log", "nginx:error.log" ]
      else [ "nginx:error.log", "nginx:access.log" ]
      end
    end

    # Never trust the caller's line count into an allocation: a stray
    # ?lines=99999999 would ask for a 40 GB seek window.
    def line_count(lines)
      lines.to_i.clamp(1, LINE_CHOICES.max)
    end

    def read_config(path)
      File.read(path)
    rescue SystemCallError, IOError
      nil
    end

    def decode(bytes)
      bytes.to_s.b.force_encoding(Encoding::UTF_8).scrub("?")
    end
  end
end
