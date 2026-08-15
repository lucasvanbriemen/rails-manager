require "test_helper"

# The crontab below is verbatim `crontab -l -u <user>` output from
# server.ltvb.nl for every user that has one, banner-separated the way the
# export's crontabs.txt spells it. It is the whole point of this test file: the
# model exists to describe these nine lines, and every shape in them -- a cd
# into an app directory, PATH-resolved interpreters, a Plesk binary, a root job,
# a discarded output stream -- has to survive being stored and read back.
#
# djtim.eu_aqwzxapl85w and voordezorgmanagement._rhc4zy0iyc are in the list with
# no job lines on purpose: a user with an empty crontab must produce no rows.
class ScheduledJobTest < ActiveSupport::TestCase
  REAL_CRONTABS = <<~CRON
    # user: root
    * * * * * /usr/local/bin/rails-deploy-watch.sh
    # user: ltvb
    SHELL="/bin/bash"
    * * * * * cd /var/www/vhosts/ltvb.nl/ai.ltvb.nl && php artisan schedule:run >> /dev/null 2>&1
    # user: lucasvanbriemen.nl_p8c08835y9j
    MAILTO=""
    SHELL="/bin/bash"
    * * * * * /usr/bin/php '/var/www/vhosts/lucasvanbriemen.nl/calendar.lucasvanbriemen.nl/artisan' 'schedule:run'
    * * * * * /usr/bin/php '/var/www/vhosts/lucasvanbriemen.nl/email.lucasvanbriemen.nl/artisan' 'schedule:run'
    * * * * * /usr/bin/php '/var/www/vhosts/lucasvanbriemen.nl/github.lucasvanbriemen.nl/artisan' 'schedule:run'
    # user: djtim.eu_aqwzxapl85w
    MAILTO=""
    # user: rijschool-mos.nl_gze6m7rrghq
    MAILTO=""
    SHELL="/bin/sh"
    0 * * * * /opt/psa/admin/sbin/fetch_url 'https://student.rijschool-mos.nl/data/send-mail.php'
    SHELL="/bin/bash"
    0 0 * * * python3 /var/www/vhosts/rijschool-mos.nl/admin.rijschool-mos.nl/cron/get_users/main.py
    30 * * * * python3 /var/www/vhosts/rijschool-mos.nl/admin.rijschool-mos.nl/cron/getlessen/main.py
    0 * * * * python3 /var/www/vhosts/rijschool-mos.nl/admin.rijschool-mos.nl/cron/makelessen/main.py
    # user: voordezorgmanagement._rhc4zy0iyc
    MAILTO=""
  CRON

  def real_jobs = ServerInventory.parse_crontabs(REAL_CRONTABS)

  # Adopted by default, because that is what every row the migration creates is
  # and what the looser half of the validations is for.
  def build_job(**overrides)
    ScheduledJob.new({ name: "email-lucasvanbriemen-nl-schedule-run", managed: false,
                       user: "lucasvanbriemen.nl_p8c08835y9j", cron_schedule: "* * * * *",
                       argv: [ "/usr/bin/php", "/var/www/vhosts/x/artisan", "schedule:run" ],
                       environment: { "MAILTO" => "" } }.merge(overrides))
  end

  # ---- the nine real lines ---------------------------------------------------

  test "every crontab line on this server is representable" do
    jobs = real_jobs.map { |attributes| ScheduledJob.new(attributes.except(:raw)) }

    assert_equal 9, jobs.size
    jobs.each do |job|
      assert job.valid?, "#{job.name}: #{job.errors.full_messages.to_sentence}"
    end
  end

  test "a stored job round-trips back to the crontab line it came from" do
    # If this does not match, the row is describing something other than what
    # cron is running -- which is worse than having no row at all.
    lines = real_jobs.map { |attributes| ScheduledJob.new(attributes.except(:raw)).crontab_line }

    assert_includes lines,
                    "* * * * * cd /var/www/vhosts/ltvb.nl/ai.ltvb.nl && php artisan schedule:run >> /dev/null 2>&1"
    assert_includes lines, "* * * * * /usr/local/bin/rails-deploy-watch.sh"
    assert_includes lines,
                    "0 0 * * * python3 /var/www/vhosts/rijschool-mos.nl/admin.rijschool-mos.nl/cron/get_users/main.py"
  end

  test "a user whose crontab is only a MAILTO contributes no jobs" do
    assert_empty real_jobs.select { |job| job[:user].start_with?("djtim", "voordezorg") }
  end

  test "the four every-minute schedulers are the ones with no vhost between them" do
    minutely = real_jobs.select { |job| job[:cron_schedule] == "* * * * *" }.map { |job| job[:name] }

    assert_equal 5, minutely.size # three cron-only apps, github, and root's watcher
    assert_includes minutely, "ai-ltvb-nl-schedule-run"
    assert_includes minutely, "calendar-lucasvanbriemen-nl-schedule-run"
    assert_includes minutely, "email-lucasvanbriemen-nl-schedule-run"
  end

  # ---- argv is never a command string ----------------------------------------
  # cron hands its line to a shell, which is exactly the property this model
  # exists to remove. A stored value must never be able to become a command.

  test "a command string is rejected, not helpfully split" do
    job = build_job(argv: "/usr/bin/php artisan schedule:run")

    assert_not job.valid?
    assert_match(/must be an array/, job.errors[:argv].to_sentence)
  end

  test "argv must be present" do
    assert_not build_job(argv: []).valid?
    assert_not build_job(argv: nil).valid?
    assert_not build_job(argv: [ "/usr/bin/php", "" ]).valid?
  end

  test "a newline in an argv element is rejected on an adopted row too" do
    # Adopted rows get a looser argv[0] rule and nothing else: a newline would
    # add a whole directive to any unit rendered from this row later.
    job = build_job(argv: [ "php", "artisan\nExecStopPost=/bin/rm -rf /" ])

    assert_not job.valid?
    assert_match(/control character/, job.errors[:argv].to_sentence)
  end

  test "a bare command separator is rejected on an adopted row too" do
    assert_not build_job(argv: [ "python3", ";", "/bin/sh" ]).valid?
  end

  # ---- adopted rows describe, managed rows run -------------------------------

  test "an adopted row may record the bare interpreter cron resolves from PATH" do
    # `php artisan schedule:run` and `python3 .../main.py` are what the crontab
    # literally says. Refusing to store that would not stop them running, it
    # would only make them invisible again.
    job = build_job(argv: [ "python3", "/var/www/vhosts/x/cron/main.py" ])

    assert job.valid?, job.errors.full_messages.to_sentence
    assert_not job.command_resolved?
  end

  test "a managed row must name its binary absolutely, as systemd requires" do
    job = build_job(managed: true, argv: [ "python3", "/var/www/vhosts/x/cron/main.py" ])

    assert_not job.valid?
    assert_match(/absolute path/, job.errors[:argv].to_sentence)
  end

  test "root is describable but not runnable" do
    # rails-deploy-watch.sh is the most privileged thing on this box; hiding it
    # would be the opposite of useful. Rendering a unit for it is another matter.
    adopted = build_job(name: "root-bin-rails-deploy-watch", user: "root",
                        argv: [ "/usr/local/bin/rails-deploy-watch.sh" ])
    assert adopted.valid?, adopted.errors.full_messages.to_sentence
    assert adopted.runs_as_root?

    managed = build_job(name: "root-bin-rails-deploy-watch", user: "root", managed: true,
                        argv: [ "/usr/local/bin/rails-deploy-watch.sh" ])
    assert_not managed.valid?
  end

  test "a user name that is not a unix login is refused either way" do
    assert_not build_job(user: "lucas; rm -rf /").valid?
    assert_not build_job(user: "lucas; rm -rf /", managed: true).valid?
  end

  test "promotion blockers name what has to be fixed before systemd can run it" do
    assert_empty build_job.promotion_blockers

    bare = build_job(argv: [ "php", "artisan", "schedule:run" ])
    assert_equal 1, bare.promotion_blockers.size
    assert_match(/PATH/, bare.promotion_blockers.first)

    plesk = build_job(argv: [ "/opt/psa/admin/sbin/fetch_url", "https://example.com/x.php" ])
    assert plesk.plesk_dependent?
    assert_match(/Plesk binary/, plesk.promotion_blockers.first)
  end

  test "the Plesk binary one of these jobs depends on is flagged" do
    # /opt/psa/admin/sbin/fetch_url disappears with Plesk, and MAILTO is empty,
    # so student.rijschool-mos.nl's hourly mail run would stop in silence.
    job = ScheduledJob.new(real_jobs.find { |j| j[:name].include?("send-mail") }.except(:raw))

    assert job.plesk_dependent?
  end

  test "installable means the manager both owns the job and wants it running" do
    assert_not build_job.installable?, "an adopted row is never installed over"
    assert build_job(managed: true, argv: [ "/usr/bin/php", "artisan" ]).installable?
    assert_not build_job(managed: true, enabled: false, argv: [ "/usr/bin/php", "x" ]).installable?
  end

  # ---- schedule --------------------------------------------------------------

  test "a schedule is five cron fields or a macro" do
    assert build_job(cron_schedule: "30 2 * * 1-5").valid?
    assert build_job(cron_schedule: "*/5 * * * *").valid?
    assert build_job(cron_schedule: "@daily").valid?
    assert_not build_job(cron_schedule: "* * * *").valid?
    assert_not build_job(cron_schedule: "@sometimes").valid?
  end

  test "a schedule that would end the line it is written into is refused" do
    job = build_job(cron_schedule: "* * * * * /bin/sh -c curl")

    assert_not job.valid?
    assert_match(/five cron fields/, job.errors[:cron_schedule].to_sentence)
  end

  test "tabs and runs of spaces normalise, so two rows for one schedule compare equal" do
    assert_equal "0 * * * *", build_job(cron_schedule: "0\t*  *\t* *").tap(&:validate).cron_schedule
  end

  # ---- identity --------------------------------------------------------------

  test "two rows describe the same crontab line when user, schedule and argv match" do
    # The name cannot be part of it: cron has no names, ours is derived, and a
    # derivation that changed would turn one job into two.
    assert_equal build_job.signature, build_job(name: "renamed-by-hand").signature
    assert_not_equal build_job.signature, build_job(cron_schedule: "@daily").signature
    assert_not_equal build_job.signature, build_job(user: "ltvb").signature
  end

  test "a signature can be computed from a parsed crontab before any row exists" do
    parsed = real_jobs.find { |job| job[:name] == "ai-ltvb-nl-schedule-run" }
    stored = ScheduledJob.new(parsed.except(:raw))

    assert_equal stored.signature,
                 ScheduledJob.signature_for(user: parsed[:user], cron_schedule: parsed[:cron_schedule],
                                            argv: parsed[:argv])
  end

  test "the name is the unit name, so two jobs cannot claim one file" do
    build_job.save!

    assert_not build_job.valid?
    assert_not build_job(name: "not a unit name").valid?
    assert_not build_job(name: "with@an@instance").valid?
  end

  # ---- the rest of the record ------------------------------------------------

  test "a working directory has to be an absolute path" do
    assert build_job(working_directory: "/var/www/vhosts/ltvb.nl/ai.ltvb.nl").valid?
    assert build_job(working_directory: nil).valid?
    assert_not build_job(working_directory: "../../etc").valid?
  end

  test "environment values cannot smuggle a directive into a unit file" do
    assert_not build_job(environment: { "MAILTO" => "x\nExecStart=/bin/sh" }).valid?
    assert_not build_job(environment: { "bad key" => "x" }).valid?
    assert_not build_job(environment: nil).valid?
  end

  test "a job need not belong to an app" do
    # root's watcher belongs to the host, and rijschool's python scripts run
    # against an app they are not installed in.
    assert build_job(app: nil).valid?
  end

  test "scopes separate what is adopted from what the manager owns" do
    adopted = build_job.tap(&:save!)
    managed = build_job(name: "own-job", managed: true, argv: [ "/usr/bin/php", "x" ]).tap(&:save!)
    build_job(name: "retired-job", managed: true, enabled: false, argv: [ "/usr/bin/php", "x" ]).save!

    assert_equal [ adopted ], ScheduledJob.adopted.to_a
    assert_equal [ managed.name, "retired-job" ].sort, ScheduledJob.managed.pluck(:name).sort
    assert_equal 2, ScheduledJob.active.count
  end
end
