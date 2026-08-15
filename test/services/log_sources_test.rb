require "test_helper"
require "tmpdir"

# The config fixtures are real captures from server.ltvb.nl, so the parsers are
# tested against the shapes they will actually meet. The filesystem tests use a
# repo-kind app, because that is the only kind whose app_path can be pointed at
# a tmpdir — /var/www/vhosts and /var/log/ltvb do not exist off-server.
class LogSourcesTest < ActiveSupport::TestCase
  # /etc/supervisor/conf.d/github.conf, verbatim.
  GITHUB_CONF = <<~INI
    [program:laravel-queue]
    ; Queue worker for github.lucasvanbriemen.nl. Runs as the subscription user --
    ; it processes untrusted GitHub webhook payloads and must never be root.
    process_name=%(program_name)s_%(process_num)02d
    command=/usr/bin/php /var/www/vhosts/lucasvanbriemen.nl/github.lucasvanbriemen.nl/artisan queue:work --sleep=3 --tries=3 --timeout=90
    directory=/var/www/vhosts/lucasvanbriemen.nl/github.lucasvanbriemen.nl
    user=lucasvanbriemen.nl_p8c08835y9j
    environment=HOME="/var/www/vhosts/lucasvanbriemen.nl"
    autostart=true
    autorestart=true
    numprocs=3
    stopasgroup=true
    stdout_logfile=/var/log/supervisor/laravel-queue.log
    stderr_logfile=/var/log/supervisor/laravel-queue-error.log
  INI

  # /etc/php/8.3/fpm/pool.d/music.ltvb.nl.conf, comments stripped. Plesk sets
  # no error_log at all — worker output goes to the shared php8.3-fpm.log.
  PLESK_POOL = <<~INI
    [music.ltvb.nl]
    prefix = /var/www/vhosts/system/$pool
    user = ltvb
    group = psacln
    listen = php-fpm.sock
    php_value[error_reporting] = 22519
    php_value[open_basedir] = "/var/www/vhosts/ltvb.nl/:/tmp/"
    pm = ondemand
  INI

  def setup
    @dir = Dir.mktmpdir("log-sources-test")
    @app = App.new(name: "Example", app_kind: "repo", deploy_path: @dir,
                   git_repo_url: "git@github.com:x/y.git")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def write_log(name, content)
    path = File.join(@dir, "log", name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def served_app(**overrides)
    App.new({ name: "Music", app_kind: "rails", subdomain: "music", domain: "ltvb.nl",
              git_repo_url: "git@github.com:x/y.git" }.merge(overrides))
  end

  # --- discovery -----------------------------------------------------------

  test "the app's own log dir is enumerated" do
    write_log("production.log", "hello\n")
    write_log("solid_queue.log", "worker\n")

    assert_equal %w[rails:production.log rails:solid_queue.log],
                 LogSources.for(@app).map(&:id).sort
  end

  test "a directory is not offered as a log file" do
    FileUtils.mkdir_p(File.join(@dir, "log", "archive.log"))

    assert_empty LogSources.for(@app)
  end

  # --- the path rule -------------------------------------------------------

  test "a user-supplied id is matched against the discovered list, never used as a path" do
    write_log("production.log", "hello\n")
    outside = File.join(@dir, "..", "outside.log")
    File.write(outside, "secret\n")

    assert_nil LogSources.find(@app, "rails:../outside.log")
    assert_nil LogSources.find(@app, "rails:/etc/passwd")
    assert_nil LogSources.find(@app, "apache:error_log") # real group, absent file
    assert_equal "#{@dir}/log/production.log", LogSources.find(@app, "rails:production.log").path
  ensure
    FileUtils.rm_f(outside)
  end

  test "paths outside the app's roots are rejected" do
    assert LogSources.within_roots?(File.join(@dir, "log", "production.log"), @app)
    assert_not LogSources.within_roots?("/etc/shadow", @app)
    assert_not LogSources.within_roots?(File.join(@dir, "..", "escape.log"), @app)
    # A sibling directory sharing the checkout's name as a prefix is a different app.
    assert_not LogSources.within_roots?("#{@dir}.old/log/production.log", @app)
  end

  test "a served app's roots cover its site, apache and supervisor log dirs" do
    app = served_app

    assert LogSources.within_roots?("/var/log/ltvb/sites/music.ltvb.nl/error.log", app)
    assert LogSources.within_roots?("/var/www/vhosts/ltvb.nl/logs/music.ltvb.nl/error_log", app)
    assert LogSources.within_roots?("/var/log/supervisor/music-queue.log", app)
    assert_not LogSources.within_roots?("/var/log/ltvb/sites/git.ltvb.nl/error.log", app)
  end

  # A record with a blank hostname resolves fqdn to "." — File.join would then
  # make /var/log/ltvb/sites/. (every site's logs) a root of this one app.
  test "a hostname-less record contributes no site-log root" do
    app = served_app(subdomain: nil)

    assert_not LogSources.within_roots?("/var/log/ltvb/sites/git.ltvb.nl/error.log", app)
    assert_empty LogSources.for(app).select { |s| s.group == "nginx" }
  end

  test "the default source prefers production.log and falls back to whatever exists" do
    write_log("solid_queue.log", "worker\n")
    assert_equal "rails:solid_queue.log", LogSources.default(@app).id

    write_log("production.log", "hello\n")
    assert_equal "rails:production.log", LogSources.default(@app).id
  end

  # --- incremental file reads ----------------------------------------------

  test "a first read tails the file and reports the offset to resume from" do
    path = write_log("production.log", "one\ntwo\n")

    chunk = LogSources.file_chunk(path)
    assert_equal "one\ntwo\n", chunk.content
    assert_equal 8, chunk.next_byte
    assert_not chunk.reset
  end

  test "reading from the previous offset returns only what was appended" do
    path  = write_log("production.log", "one\n")
    first = LogSources.file_chunk(path)
    File.write(path, "two\nthree\n", mode: "a")

    chunk = LogSources.file_chunk(path, from_byte: first.next_byte)
    assert_equal "two\nthree\n", chunk.content
    assert_equal File.size(path), chunk.next_byte
  end

  test "an offset at EOF returns nothing and holds its position" do
    path = write_log("production.log", "one\n")

    chunk = LogSources.file_chunk(path, from_byte: 4)
    assert_equal "", chunk.content
    assert_equal 4, chunk.next_byte
  end

  test "a half-written line is held back until its newline arrives" do
    path = write_log("production.log", "one\n")
    File.write(path, "par", mode: "a")

    chunk = LogSources.file_chunk(path, from_byte: 4)
    assert_equal "", chunk.content
    # Not 7: the offset must stay before the fragment so it is re-read whole.
    assert_equal 4, chunk.next_byte

    File.write(path, "tial\n", mode: "a")
    assert_equal "partial\n", LogSources.file_chunk(path, from_byte: chunk.next_byte).content
  end

  test "a rotated file resets to its new tail instead of replaying it" do
    path = write_log("production.log", "old and long\n")
    File.write(path, "new\n") # logrotate copytruncate: same path, smaller

    chunk = LogSources.file_chunk(path, from_byte: 13)
    assert chunk.reset
    assert_equal "new\n", chunk.content
    assert_equal 4, chunk.next_byte
  end

  test "a huge backlog skips forward rather than shipping it all" do
    line = "#{'x' * 99}\n"
    path = write_log("production.log", line * ((LogSources::MAX_CHUNK_BYTES / 100) + 50))

    chunk = LogSources.file_chunk(path, from_byte: 0)
    assert chunk.truncated
    assert_operator chunk.content.bytesize, :<=, LogSources::MAX_CHUNK_BYTES
    assert_equal File.size(path), chunk.next_byte
    # Skipping lands mid-line; the fragment is dropped, not shown as a line.
    assert_equal line, chunk.content.lines.first
  end

  test "a tail keeps only the requested number of whole lines" do
    path = write_log("production.log", (1..50).map { |i| "line #{i}\n" }.join)

    chunk = LogSources.file_chunk(path, lines: 5)
    assert_equal 5, chunk.content.lines.size
    assert_equal "line 50\n", chunk.content.lines.last
    assert_equal File.size(path), chunk.next_byte
  end

  test "an absurd line count is clamped rather than allocated" do
    path = write_log("production.log", "one\n")

    assert_equal "one\n", LogSources.file_chunk(path, lines: 99_999_999).content
  end

  test "invalid encoding is scrubbed, not raised" do
    path = write_log("production.log", "ok\n")
    File.binwrite(path, "caf\xC3\xA9 \xFF\n", mode: "a")

    chunk = LogSources.file_chunk(path, from_byte: 3)
    assert chunk.content.valid_encoding?
    assert_includes chunk.content, "café"
  end

  test "an unreadable file explains itself instead of raising" do
    chunk = LogSources.file_chunk(File.join(@dir, "log", "gone.log"), from_byte: 10)

    assert_includes chunk.content, "could not read"
    assert_equal 10, chunk.next_byte
  end

  # --- journald ------------------------------------------------------------

  test "a malformed cursor is dropped rather than passed to journalctl" do
    source = LogSources::Source.new(id: "journal:x", label: "x", group: "journal",
                                    unit: "ltvb-app@music.ltvb.nl")

    chunk = LogSources.journal_chunk(source, cursor: "s=1; rm -rf /")
    assert_nil chunk.cursor
  end

  test "journal sources are limited to units systemd has actually loaded" do
    # Off-server there is no systemctl at all, so nothing is offered — the
    # logs page must render either way.
    assert_nothing_raised { LogSources.journal_sources(served_app) }
    assert_empty LogSources.journal_sources(served_app).reject { |s| s.unit.start_with?("ltvb-") }
  end

  test "journal candidates are the app's own unit plus its registered workers" do
    app = App.create!(name: "Music", app_kind: "rails", subdomain: "music", domain: "ltvb.nl",
                      ruby_version: "3.3.8", git_repo_url: "git@github.com:x/y.git",
                      primary_db_kind: "external")
    ProcessService.create!(app: app, name: "music-solid-queue", kind: "solid_queue", user: "ltvb",
                           working_directory: app.app_path, argv: [ "/usr/bin/bundle", "exec", "bin/jobs" ])
    # Belongs to no app: a host-wide worker must not leak into an app's logs.
    ProcessService.create!(name: "host-backup", kind: "generic", user: "ltvb",
                           working_directory: "/var/www/vhosts/ltvb.nl", argv: [ "/usr/bin/rsync", "-a" ])

    assert_equal %w[ltvb-app@music.ltvb.nl music-solid-queue], LogSources.journal_units(app).sort
  end

  test "an unsaved app claims no worker units" do
    # where(app_id: nil) would otherwise match every host-wide worker.
    assert_equal %w[ltvb-app@music.ltvb.nl], LogSources.journal_units(served_app)
  end

  # --- supervisor ----------------------------------------------------------

  test "supervisor programs are parsed out of the real conf" do
    programs = LogSources.parse_supervisor(GITHUB_CONF)

    assert_equal %w[laravel-queue], programs.keys
    assert_equal "/var/log/supervisor/laravel-queue.log", programs["laravel-queue"]["stdout_logfile"]
    # `;` comments must not become settings.
    assert_not programs["laravel-queue"].key?("; Queue worker for github.lucasvanbriemen.nl. Runs as the subscription user --")
  end

  test "a supervisor program belongs to the app whose checkout it runs in" do
    settings = LogSources.parse_supervisor(GITHUB_CONF)["laravel-queue"]
    path     = "/var/www/vhosts/lucasvanbriemen.nl/github.lucasvanbriemen.nl"

    assert LogSources.supervises?(settings, path)
    assert_not LogSources.supervises?(settings, "#{path}.old")
    assert_not LogSources.supervises?(settings, "/var/www/vhosts/ltvb.nl/music.ltvb.nl")
  end

  test "supervisor log sentinels and unresolvable placeholders are skipped" do
    assert_nil LogSources.supervisor_log_path("AUTO", "worker")
    assert_nil LogSources.supervisor_log_path("syslog", "worker")
    assert_nil LogSources.supervisor_log_path("", "worker")
    assert_nil LogSources.supervisor_log_path("relative.log", "worker")
    assert_nil LogSources.supervisor_log_path("/var/log/supervisor/%(process_num)02d.log", "worker")
    assert_equal "/var/log/supervisor/worker.log",
                 LogSources.supervisor_log_path("/var/log/supervisor/%(program_name)s.log", "worker")
  end

  # --- php-fpm -------------------------------------------------------------

  test "a Plesk pool names no error log" do
    assert_nil LogSources.pool_error_log(PLESK_POOL)
  end

  test "an explicit pool error log is read, quoted or not" do
    assert_equal "/var/log/ltvb/sites/music.ltvb.nl/php-fpm.log",
                 LogSources.pool_error_log(%(php_admin_value[error_log] = "/var/log/ltvb/sites/music.ltvb.nl/php-fpm.log"\n))
    assert_equal "/var/log/ltvb/sites/x/php-fpm.log",
                 LogSources.pool_error_log("php_value[error_log] = /var/log/ltvb/sites/x/php-fpm.log\n")
  end

  test "a relative pool error log is ignored rather than guessed at" do
    assert_nil LogSources.pool_error_log("php_admin_value[error_log] = log/php-fpm.log\n")
  end
end
