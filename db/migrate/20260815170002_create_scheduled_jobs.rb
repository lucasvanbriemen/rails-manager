# Cron is the last unmodelled thing that runs code on this server, and the most
# dangerous one to lose: three of the 25 apps have no vhost at all and exist
# *only* because a crontab line runs their scheduler every minute. Nothing in
# the manager knew they were there — `grep -c cron db/schema.rb` returned 0 —
# and the Plesk export does not contain a crontabs.txt either, so an import
# could not have discovered them.
#
# The nine rows below were read off the server with `crontab -l -u <user>` for
# every user that has one, and are adopted with managed: false: describe, do not
# write. Promoting one to managed: true is a per-job decision, and
# ScheduledJob#promotion_blockers says what has to be fixed first.
class CreateScheduledJobs < ActiveRecord::Migration[8.0]
  VHOSTS = "/var/www/vhosts".freeze
  LVB    = "#{VHOSTS}/lucasvanbriemen.nl".freeze
  MOS    = "#{VHOSTS}/rijschool-mos.nl/admin.rijschool-mos.nl".freeze

  # Crontab-level assignments are part of the job's environment, not decoration:
  # MAILTO="" is why nobody has been getting mail about these, and SHELL is what
  # `cd x && y` was interpreted by.
  BASH   = { "SHELL" => "/bin/bash" }.freeze
  QUIET  = { "MAILTO" => "", "SHELL" => "/bin/bash" }.freeze

  def change
    create_table :scheduled_jobs do |t|
      # Optional: the three Laravel schedulers belong to an app, but root's
      # deploy watcher belongs to the host and rijschool's python scripts run
      # against an app they are not installed in.
      t.references :app, foreign_key: true

      # Cron lines have no identity of their own, so a name has to be invented.
      # ServerInventory.job_name derives exactly these, deterministically, so a
      # later import recognises what is already here instead of adopting it
      # twice. Shaped like a unit name because that is what it becomes.
      t.string  :name, null: false

      t.string  :user, null: false
      # Five cron fields ("* * * * *") or a cron macro ("@daily"). Named for the
      # dialect, not just "schedule": a systemd timer's OnCalendar= is a
      # different syntax with different semantics, and a row that has been
      # promoted to one will need its own column rather than a reinterpretation
      # of this one.
      t.string  :cron_schedule, null: false

      # An argv ARRAY, never a command string — the same rule as
      # process_services, for the same reason: a stored value must never be able
      # to become a second command. `cd <dir> && ...` is not part of it either;
      # that is a shell construct, and the directory is a column.
      t.json    :argv, null: false, default: []
      t.string  :working_directory
      t.json    :environment, null: false, default: {}

      # `>> /dev/null 2>&1` is a redirection, not an argument. Recorded as a flag
      # because dropping it would silently start mailing output to a user who
      # has been discarding it for years.
      t.boolean :discard_output, null: false, default: false

      # managed: false = adopted read-only. The row describes a crontab line
      # that cron still owns and the manager must not rewrite.
      t.boolean :managed, null: false, default: true
      # enabled: false retires a job without losing its definition or its notes.
      t.boolean :enabled, null: false, default: true

      t.text    :notes

      t.timestamps
    end

    # The name becomes a unit/timer name; two rows sharing one would race to own
    # a file in /etc/systemd/system.
    add_index :scheduled_jobs, :name, unique: true
    add_index :scheduled_jobs, :managed

    reversible { |dir| dir.up { adopt_existing_jobs! } }
  end

  private

  # insert_all needs every row to carry the same keys, so the two optional ones
  # are spelled out rather than left to the column defaults.
  DEFAULTS = { working_directory: nil, discard_output: false }.freeze

  def adopt_existing_jobs!
    rows = adopted_rows.map do |row|
      fqdn = row.delete(:fqdn)
      DEFAULTS.merge(row).merge(app_id: app_id_for(fqdn), managed: false)
    end
    scheduled_jobs.insert_all(rows, record_timestamps: true)
  end

  # Defined inline rather than using ScheduledJob: a migration has to keep
  # working after the model changes.
  def scheduled_jobs
    @scheduled_jobs ||= Class.new(ActiveRecord::Base) { self.table_name = "scheduled_jobs" }
  end

  # nil for the apps that have no App row yet — which is most of them, because
  # the import that would have created them reads a crontabs.txt the export does
  # not have. The association is optional precisely so adoption does not depend
  # on that being fixed first.
  def app_id_for(fqdn)
    return nil if fqdn.blank?

    subdomain, _, domain = fqdn.to_s.partition(".")
    connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        [ "SELECT id FROM apps WHERE subdomain = ? AND domain = ? LIMIT 1", subdomain, domain ]
      )
    )
  end

  # Transcribed from `crontab -l -u <user>` on server.ltvb.nl. Five users have a
  # crontab; djtim.eu_aqwzxapl85w's and voordezorgmanagement._rhc4zy0iyc's hold
  # only a MAILTO, so nine job lines exist in total.
  def adopted_rows
    laravel_schedulers + [ deploy_watcher ] + rijschool_jobs
  end

  # The three apps that exist only because of these lines, plus github's, which
  # also serves HTTP. Written as `/usr/bin/php '<dir>/artisan' 'schedule:run'`.
  def laravel_schedulers
    [
      { fqdn: "ai.ltvb.nl", name: "ai-ltvb-nl-schedule-run", user: "ltvb",
        cron_schedule: "* * * * *", argv: [ "php", "artisan", "schedule:run" ],
        working_directory: "#{VHOSTS}/ltvb.nl/ai.ltvb.nl", environment: BASH,
        discard_output: true,
        notes: <<~TXT
          Laravel scheduler for ai.ltvb.nl, the only thing that runs this app — it has
          no vhost. Spelled `cd <dir> && php artisan schedule:run >> /dev/null 2>&1`, so
          it is the one job here that depends on cron's PATH to find `php` AND on a
          shell to do the cd. Both are columns now.
        TXT
      },
      { fqdn: "calendar.lucasvanbriemen.nl", name: "calendar-lucasvanbriemen-nl-schedule-run",
        user: "lucasvanbriemen.nl_p8c08835y9j", cron_schedule: "* * * * *",
        argv: [ "/usr/bin/php", "#{LVB}/calendar.lucasvanbriemen.nl/artisan", "schedule:run" ],
        environment: QUIET,
        notes: "Laravel scheduler for calendar.lucasvanbriemen.nl — no vhost serves this app."
      },
      { fqdn: "email.lucasvanbriemen.nl", name: "email-lucasvanbriemen-nl-schedule-run",
        user: "lucasvanbriemen.nl_p8c08835y9j", cron_schedule: "* * * * *",
        argv: [ "/usr/bin/php", "#{LVB}/email.lucasvanbriemen.nl/artisan", "schedule:run" ],
        environment: QUIET,
        notes: "Laravel scheduler for email.lucasvanbriemen.nl — no vhost serves this app."
      },
      { fqdn: "github.lucasvanbriemen.nl", name: "github-lucasvanbriemen-nl-schedule-run",
        user: "lucasvanbriemen.nl_p8c08835y9j", cron_schedule: "* * * * *",
        argv: [ "/usr/bin/php", "#{LVB}/github.lucasvanbriemen.nl/artisan", "schedule:run" ],
        environment: QUIET,
        notes: <<~TXT
          Laravel scheduler for github.lucasvanbriemen.nl. Unlike the other three this
          app does serve HTTP, and it also has a supervisor queue worker
          (process_services: github-laravel-queue) — scheduler and worker are separate
          processes and stopping one does not stop the other.
        TXT
      }
    ]
  end

  # The most privileged thing on this box: root, every minute, driving a build as
  # each app's own user. It exists because Plesk's post-deploy actions never fire
  # on webhook deploys, so it dies with Plesk — and the manager's own deploy
  # runner is what replaces it.
  def deploy_watcher
    { fqdn: nil, name: "root-bin-rails-deploy-watch", user: "root", cron_schedule: "* * * * *",
      argv: [ "/usr/local/bin/rails-deploy-watch.sh" ], environment: {},
      notes: <<~TXT
        Root's every-minute Plesk deploy watcher. Polls
        /usr/local/psa/var/modules/git/git_db.db for a changed deployedCommitHash, then
        runs /usr/local/bin/rails-deploy-build.sh as the app's own user.
        Reads the Plesk git database and shells out to `plesk db`, so it stops working
        the moment Plesk is removed. Nothing has to replace it: DeployRunner plus the
        webhook endpoint already cover both halves of what it does. Turn it off in the
        same change that removes Plesk, not before.
      TXT
    }
  end

  # rijschool-mos.nl's four jobs, the only ones here that are not schedulers.
  def rijschool_jobs
    user = "rijschool-mos.nl_gze6m7rrghq"
    [
      { fqdn: "student.rijschool-mos.nl", name: "rijschool-mos-nl-gze6m7rrghq-data-send-mail",
        user: user, cron_schedule: "0 * * * *",
        argv: [ "/opt/psa/admin/sbin/fetch_url", "https://student.rijschool-mos.nl/data/send-mail.php" ],
        environment: { "MAILTO" => "", "SHELL" => "/bin/sh" },
        notes: <<~TXT
          Hourly mail run for student.rijschool-mos.nl, invoked by fetching its own URL.
          BREAKS WITH PLESK: /opt/psa/admin/sbin/fetch_url is a Plesk binary and goes
          away with it. curl or wget is a drop-in, but somebody has to make the change —
          the failure mode is silent, because MAILTO is empty.
        TXT
      }
    ] + %w[get_users getlessen makelessen].zip([ "0 0 * * *", "30 * * * *", "0 * * * *" ]).map do |script, schedule|
      { fqdn: "admin.rijschool-mos.nl", name: "admin-rijschool-mos-nl-#{script.tr('_', '-')}-main",
        user: user, cron_schedule: schedule,
        argv: [ "python3", "#{MOS}/cron/#{script}/main.py" ], environment: BASH,
        notes: <<~TXT
          #{script}: a python job living inside admin.rijschool-mos.nl's checkout but run
          by cron, not by the app. Resolves `python3` from cron's PATH, so it needs an
          absolute interpreter before it can be promoted to a systemd timer — and there
          is no requirements.txt in the checkout recording what it imports.
        TXT
      }
    end
  end
end
