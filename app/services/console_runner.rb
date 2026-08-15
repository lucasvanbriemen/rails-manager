require "pty"
require "etc"
require "uri"
require "cgi"

# Runs one interactive console for a managed app inside a Solid Queue worker
# thread, bridging it to the ConsoleSession row: PTY output is appended to
# `output`, commands arrive via the `pending_input` mailbox, and a heartbeat
# lets the web tier detect a killed worker (orphan sweep).
#
# The session's `kind` picks what gets spawned — `rails console`, `php artisan
# tinker`, the app's own `mysql`, or a login shell. Everything downstream of the
# spawn (PTY draining, UTF-8 carry, ANSI stripping, idle timeout, termination)
# is identical for all of them.
#
#   ConsoleRunner.new(session).call
class ConsoleRunner
  class ConsoleUnavailable < StandardError; end

  POLL_INTERVAL       = 0.5  # max seconds between DB polls; PTY output wakes us sooner
  HEARTBEAT_INTERVAL  = 5.seconds
  TRIM_EVERY          = 100  # loop iterations between output trims

  # Everything that keeps a REPL scrapeable through a dumb terminal: TERM=dumb
  # switches Reline/PsySH/readline to plain line IO (no redraws, no completion
  # rendering), and a real pager would block forever on a PTY nobody presses
  # keys on.
  DUMB_TERMINAL = {
    "TERM"     => "dumb",
    "NO_COLOR" => "1",
    "PAGER"    => "cat"
  }.freeze

  # Schemes/adapters that a `mysql` client can actually open.
  MYSQL_ADAPTERS = %w[mysql mysql2 mariadb].freeze

  # Credential plumbing, kept pure (text in, hash out) so it can be reasoned
  # about — and exercised — without a PTY or a server.
  class << self
    # KEY=value pairs from a .env: optional `export`, optional matching quotes,
    # comments and blanks skipped. Deliberately not a shell parser — no variable
    # expansion, no command substitution, no inline-comment stripping (a `#` is
    # legal inside a password).
    def parse_env(text)
      text.to_s.each_line.filter_map { |line|
        line = line.strip.delete_prefix("export ")
        next if line.empty? || line.start_with?("#")

        key, value = line.split("=", 2)
        next unless value && key.to_s.strip.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

        [ key.strip, unquote(value.strip) ]
      }.to_h
    end

    def unquote(value)
      quoted = value.length >= 2 && [ '"', "'" ].include?(value[0]) && value[-1] == value[0]
      quoted ? value[1..-2].to_s : value
    end

    # Laravel's DB_* keys, or a Rails DATABASE_URL. Returns nil — not a partial
    # hash — unless this really is a MySQL app with a database to open, so the
    # caller can say why instead of spawning a client that sits there prompting
    # for a password on a PTY nobody is watching.
    def mysql_options(vars)
      options = mysql_url_options(vars["DATABASE_URL"]) || dotenv_mysql_options(vars)
      return nil if options.nil?

      options = options.transform_values { |v| v.to_s.strip.presence }
      options[:database].present? ? options : nil
    end

    def dotenv_mysql_options(vars)
      connection = vars["DB_CONNECTION"].to_s.downcase
      # Laravel defaults to mysql when the key is absent; anything explicitly
      # else (sqlite, pgsql) is not ours to open.
      return nil if connection.present? && !MYSQL_ADAPTERS.include?(connection)

      { host: vars["DB_HOST"], port: vars["DB_PORT"], database: vars["DB_DATABASE"],
        user: vars["DB_USERNAME"], password: vars["DB_PASSWORD"] }
    end

    # mysql2://user:p%40ss@host:3306/dbname — credentials inside a URL are
    # percent-encoded, so they must be decoded before reaching the client.
    def mysql_url_options(url)
      return nil if url.blank?

      uri = URI.parse(url)
      return nil unless MYSQL_ADAPTERS.include?(uri.scheme.to_s.downcase)

      { host: uri.host, port: uri.port, database: uri.path.to_s.delete_prefix("/"),
        user: uri.user && CGI.unescape(uri.user),
        password: uri.password && CGI.unescape(uri.password) }
    rescue URI::InvalidURIError
      nil
    end
  end

  def initialize(session)
    @session = session
    @app     = session.app
    @kind    = session.kind.presence || "rails"
    @carry   = "".b   # bytes of a UTF-8 char split across PTY reads
  end

  def call
    @session.update!(status: "running", started_at: Time.current,
                     heartbeat_at: Time.current)
    @last_activity = Time.current

    env, argv = console_command
    announce(argv)

    Bundler.with_unbundled_env do
      # PTY.spawn forwards to Process.spawn, so the env hash + chdir: work.
      # argv is always >1 element, so it is exec'd directly — a one-element
      # argv would be handed to a shell instead.
      reader, writer, pid = PTY.spawn(env, *argv, chdir: @app.app_path)
      begin
        reason = run_loop(reader, writer, pid)
        terminate(writer, pid)
        @session.finish!(reason)
      rescue StandardError
        terminate(writer, pid)
        raise
      end
    end
    @session.trim_output!
  rescue StandardError => e
    @session.append_output("\n== console error: #{e.class}: #{e.message} ==\n")
    @session.update!(status: "failed", closed_at: Time.current, pending_input: nil)
  end

  private

  def run_loop(reader, writer, pid)
    iterations = 0
    loop do
      return "exited" unless drain(reader)
      return "exited" if PTY.check(pid)

      heartbeat!
      close_requested, command = ConsoleSession.where(id: @session.id)
                                               .pick(:close_requested, :pending_input)
      return "requested" if close_requested

      if command
        # Read-then-clear is safe: submit_input's CAS only writes while the
        # mailbox is nil, and it stays non-nil until this clear.
        ConsoleSession.where(id: @session.id).update_all(pending_input: nil)
        writer.write(command.delete("\r") + "\n")
        touch_activity
      end

      return "idle_timeout" if Time.current - @last_activity > ConsoleSession::IDLE_TIMEOUT

      # Wakes immediately on new PTY output, else settles at DB-poll cadence.
      IO.select([ reader ], nil, nil, POLL_INTERVAL)

      @session.trim_output! if ((iterations += 1) % TRIM_EVERY).zero?
    end
  end

  # Pull everything currently buffered on the PTY into the transcript.
  # Returns false once the console process has closed its end.
  def drain(reader)
    loop do
      chunk = reader.read_nonblock(4096, exception: false)
      return true if chunk == :wait_readable
      return false if chunk.nil? # EOF

      @session.append_output(sanitize(chunk))
      touch_activity
    end
  rescue Errno::EIO # Linux PTY: slave side closed
    false
  end

  def terminate(writer, pid)
    begin
      writer.write("exit\n")
    rescue StandardError
      nil
    end
    8.times do # ~2s grace for a clean exit
      return reap(pid) if PTY.check(pid)

      sleep 0.25
    end
    Process.kill("TERM", pid)
    sleep 1
    Process.kill("KILL", pid) unless PTY.check(pid)
    reap(pid)
  rescue Errno::ESRCH
    reap(pid)
  end

  def reap(pid)
    Process.wait(pid)
  rescue Errno::ECHILD
    nil
  end

  # => [env hash, argv]. One place that decides what a session actually runs.
  def console_command
    case @kind
    when "rails"   then [ rails_env, [ "bundle", "exec", "rails", "console", "-e", "production" ] ]
    when "laravel" then [ php_env, [ php_binary, "artisan", "tinker", "--no-ansi" ] ]
    when "mysql"   then mysql_command
    when "shell"   then [ shell_env, [ "bash", "-l" ] ]
    else raise ConsoleUnavailable, "unknown console kind #{@kind.inspect}"
    end
  end

  # The app's normal shell env (real credentials, no dummy secret) plus, on top
  # of the dumb-terminal settings, $IRBRC pointing at our rc so a stray ~/.irbrc
  # in the webspace can't re-enable autocomplete/pager rendering.
  def rails_env
    AppShellEnv.rails(@app, DUMB_TERMINAL.merge(
      "IRB_USE_AUTOCOMPLETE" => "false",
      "IRBRC"                => Rails.root.join("config/console_session.irbrc").to_s
    ))
  end

  # Non-Ruby kinds: the manager's own bundler/ruby context stripped out (that is
  # all AppShellEnv.repo does) and the webspace as HOME, which is where composer,
  # PsySH history and the app's own config expect to write — the same HOME the
  # supervisor units for these apps set.
  def php_env(extra = {})
    AppShellEnv.repo(DUMB_TERMINAL.merge("HOME" => @app.webspace_root).merge(extra))
  end

  # A login shell gets the environment its runtime would: rbenv on PATH for a
  # Ruby app, the plain webspace env otherwise. `bash -l` then sources the
  # user's profile on top, which is what makes nvm/composer resolve.
  def shell_env
    @app.ruby? ? AppShellEnv.rails(@app, DUMB_TERMINAL) : php_env
  end

  # Version-suffixed binary when the app pins one (8.3 and 8.4 both exist on
  # this host and artisan is version-sensitive), plain `php` otherwise.
  def php_binary
    version = @app.php_version.to_s
    return "php" unless version.match?(/\A\d+\.\d+\z/)

    path = "/usr/bin/php#{version}"
    File.executable?(path) ? path : "php"
  end

  # The app's OWN database, read from the .env it boots with. The password goes
  # in MYSQL_PWD rather than --password=: argv is world-readable in `ps`, while
  # the environment of a running process is only visible to its own uid and root.
  def mysql_command
    options = self.class.mysql_options(app_env_vars)
    unless options
      raise ConsoleUnavailable,
            "no MySQL credentials in this app's .env (need DB_CONNECTION=mysql with " \
            "DB_DATABASE/DB_USERNAME, or a mysql:// DATABASE_URL)"
    end

    argv = [ "mysql" ]
    argv += [ "--host", options[:host].to_s ] if options[:host].present?
    argv += [ "--port", options[:port].to_s ] if options[:port].present?
    argv += [ "--user", options[:user].to_s ] if options[:user].present?
    argv += [ "--database", options[:database].to_s ]

    [ php_env("MYSQL_PWD" => options[:password].to_s), argv ]
  end

  # Prefer the .env on disk over our stored copy: DeployRunner writes one from
  # the other, but a hand-edit on the server is what the app is actually using,
  # and connecting with stale credentials is the confusing kind of failure.
  def app_env_vars
    self.class.parse_env(read_dotenv.presence || @app.env_text)
  end

  def read_dotenv
    File.read(File.join(@app.app_path, ".env"))
  rescue SystemCallError, IOError
    nil
  end

  # Header line so the transcript records what was launched and as whom. The
  # console runs as the MANAGER's user, which is only the app's own user for the
  # ltvb.nl webspace — for the other five subscriptions the mismatch shows up as
  # permission errors, so say it up front rather than let it be a mystery.
  def announce(argv)
    banner = "== #{@kind} console: #{argv.join(' ')} (as #{process_user}, in #{@app.app_path}) ==\n"
    if process_user != @app.deploy_user
      banner += "!! running as #{process_user}, not this app's user (#{@app.deploy_user}) — " \
                "writes may fail or land with the wrong owner\n"
    end
    @session.append_output(banner)
  end

  def process_user
    Etc.getpwuid(Process.uid).name
  rescue ArgumentError
    Process.uid.to_s
  end

  # PTY output can split a UTF-8 char across reads and may carry ANSI escapes
  # from app code (TERM=dumb suppresses IRB's own). Carry incomplete trailing
  # bytes to the next read, scrub what's genuinely invalid, strip CSI/OSC
  # sequences, and drop \r so the <pre> doesn't double-space.
  def sanitize(chunk)
    bytes = @carry + chunk.b
    @carry = "".b
    text = bytes.force_encoding(Encoding::UTF_8)

    unless text.valid_encoding?
      tail = incomplete_tail(bytes)
      if tail.positive?
        @carry = bytes[-tail..].b
        text = bytes[0...-tail].force_encoding(Encoding::UTF_8)
      end
      text = text.scrub("?")
    end

    text.gsub(/\e\[[0-9;?]*[ -\/]*[@-~]/, "") # CSI
        .gsub(/\e\][^\a\e]*(\a|\e\\)?/, "")   # OSC
        .delete("\r")
  end

  # Number of trailing bytes that look like the start of an unfinished UTF-8
  # sequence (a lead byte with too few continuation bytes after it).
  def incomplete_tail(bytes)
    (1..3).each do |n|
      break if n > bytes.bytesize

      lead = bytes.getbyte(-n)
      return 0 if lead < 0x80                  # ASCII — nothing unfinished
      next if lead < 0xC0                      # continuation byte, look further back

      expected = if lead >= 0xF0 then 4
      elsif lead >= 0xE0 then 3
      else 2
      end
      return expected > n ? n : 0
    end
    0
  end

  def touch_activity
    @last_activity = Time.current
    if @activity_written_at.nil? || Time.current - @activity_written_at > 2
      @activity_written_at = Time.current
      ConsoleSession.where(id: @session.id).update_all(last_activity_at: Time.current)
    end
  end

  def heartbeat!
    return if @heartbeat_at && Time.current - @heartbeat_at < ConsoleRunner::HEARTBEAT_INTERVAL

    @heartbeat_at = Time.current
    ConsoleSession.where(id: @session.id).update_all(heartbeat_at: Time.current)
  end
end
