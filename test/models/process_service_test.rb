require "test_helper"

class ProcessServiceTest < ActiveSupport::TestCase
  def build_service(**overrides)
    ProcessService.new({
      name: "music-solid-queue", kind: "solid_queue", user: "ltvb",
      working_directory: "/var/www/vhosts/ltvb.nl/music.ltvb.nl",
      argv: [ "/var/www/vhosts/ltvb.nl/.rbenv/versions/3.3.8/bin/bundle", "exec", "bin/jobs" ],
      environment: { "HOME" => "/var/www/vhosts/ltvb.nl", "RAILS_ENV" => "production" }
    }.merge(overrides))
  end

  test "the four real worker shapes on this server are representable" do
    [
      { kind: "solid_queue", argv: [ "/opt/rbenv/versions/3.3.8/bin/bundle", "exec", "bin/jobs" ] },
      { kind: "cable", argv: [ "/opt/rbenv/versions/3.3.8/bin/bundle", "exec", "puma", "-e",
                               "production", "-b", "tcp://127.0.0.1:28082", "cable/config.ru" ] },
      { kind: "laravel_queue", argv: [ "/usr/bin/php", "artisan", "queue:work", "--tries=3" ] },
      { kind: "python", argv: [ "/var/www/vhosts/ltvb.nl/music.ltvb.nl/vendor/kokoro/bin/python",
                                "script/kokoro_server.py" ] }
    ].each do |attrs|
      service = build_service(**attrs)
      assert service.valid?, "#{attrs[:kind]}: #{service.errors.full_messages.to_sentence}"
    end
  end

  test "kind must be one the manager knows how to run" do
    assert_not build_service(kind: "systemd-timer").valid?
  end

  test "a worker need not belong to an app" do
    assert build_service(app: nil).valid?
  end

  # --- argv is never a command string ---------------------------------------
  # supervisor's `command=` is a string it splits itself; that is the shape this
  # model exists to stop, so it must not be accepted even as a convenience.

  test "a command string is rejected, not helpfully split" do
    service = build_service(argv: "/usr/bin/php artisan queue:work")

    assert_not service.valid?
    assert_match(/must be an array/, service.errors[:argv].to_sentence)
  end

  test "argv must be present and start with an absolute path" do
    assert_not build_service(argv: []).valid?
    assert_not build_service(argv: nil).valid?
    assert_not build_service(argv: [ "php", "artisan" ]).valid?
    assert_not build_service(argv: [ "/usr/bin/php", "" ]).valid?
  end

  test "a newline in an argv element is rejected" do
    service = build_service(argv: [ "/usr/bin/php", "artisan\nExecStopPost=/bin/rm -rf /" ])

    assert_not service.valid?
    assert_match(/control character/, service.errors[:argv].to_sentence)
  end

  # There is no shell, so these are ordinary arguments and must be storable —
  # rejecting them would be cargo-cult validation.
  test "shell metacharacters in an argument are allowed because nothing parses them" do
    assert build_service(argv: [ "/bin/echo", "; rm -rf /", "$(id)" ]).valid?
  end

  # --- environment ----------------------------------------------------------

  test "a newline in an env value is rejected" do
    service = build_service(environment: { "FOO" => "bar\nExecStartPre=/bin/sh -c id" })

    assert_not service.valid?
    assert_match(/control character/, service.errors[:environment].to_sentence)
  end

  test "an env key that is not a shell-safe identifier is rejected" do
    assert_not build_service(environment: { "FOO BAR" => "1" }).valid?
    assert_not build_service(environment: { "1FOO" => "1" }).valid?
  end

  test "environment must be a hash" do
    assert_not build_service(environment: [ "HOME=/root" ]).valid?
    assert_not build_service(environment: nil).valid?
    # A new record gets the column default, so "no env" is expressible.
    assert_equal({}, ProcessService.new.environment)
  end

  # --- identity, user, paths ------------------------------------------------

  test "the name has to be usable as a systemd unit name before it is stored" do
    [ "../../etc/passwd", "a/b", "with space", "has@instance", "x;reboot",
      "name\nExecStart=/bin/sh" ].each do |name|
      assert_not build_service(name: name).valid?, "accepted #{name.inspect}"
    end
  end

  test "names are normalised so two rows cannot claim one unit file" do
    build_service.save!
    duplicate = build_service(name: "  Music-Solid-Queue  ")

    assert_equal "music-solid-queue", duplicate.name
    assert_not duplicate.valid?
    assert_match(/taken/, duplicate.errors[:name].to_sentence)
  end

  test "root is rejected as the user of a managed worker" do
    assert_not build_service(user: "root").valid?
  end

  test "plesk webspace owners are accepted as users" do
    assert build_service(user: "lucasvanbriemen.nl_p8c08835y9j").valid?
  end

  test "the working directory must be an absolute path without traversal" do
    assert_not build_service(working_directory: "music.ltvb.nl").valid?
    assert_not build_service(working_directory: "/var/www/../etc").valid?
  end

  # --- adoption -------------------------------------------------------------

  test "adopted rows are described but never written over" do
    adopted = build_service(managed: false)

    assert adopted.adopted?
    assert_not adopted.installable?
  end

  test "a managed row is only installed while it is enabled" do
    assert build_service(managed: true, enabled: true).installable?
    assert_not build_service(managed: true, enabled: false).installable?
  end

  test "the unit name and path are derived from the record" do
    service = build_service

    assert_equal "music-solid-queue.service", service.unit_name
    assert_equal "/etc/systemd/system/music-solid-queue.service", service.unit_path
  end

  test "the description falls back to the record when there are no notes" do
    assert_equal "music-solid-queue (solid_queue) — managed by apps.ltvb.nl",
                 build_service(notes: nil).description_line
    assert_equal "Runs the every-minute IMAP fetch.",
                 build_service(notes: "\nRuns the every-minute IMAP fetch.\nMore detail.\n").description_line
  end

  # The preview exists for humans; argv_list is the only executable form.
  test "the command preview quotes arguments so it cannot be misread" do
    service = build_service(argv: [ "/bin/echo", "two words", "; rm -rf /" ])

    assert_equal "/bin/echo two\\ words \\;\\ rm\\ -rf\\ /", service.command_preview
  end

  test "a record renders its own unit" do
    unit = build_service.render_unit

    assert_includes unit, "User=ltvb"
    assert_includes unit, %("/var/www/vhosts/ltvb.nl/.rbenv/versions/3.3.8/bin/bundle" "exec" "bin/jobs")
  end
end
