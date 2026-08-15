# Gives the manager a place to describe the seven background workers that keep
# the server running but have never been modelled: three hand-written systemd
# units and four supervisor programs. Nothing here changes what is running —
# every adopted row is inserted with managed: false, which means "describe, do
# not write". Flipping a row to managed: true is a deliberate, per-worker
# migration off supervisor, done one worker at a time.
class CreateProcessServices < ActiveRecord::Migration[8.0]
  # The rbenv the three Rails workers actually use today. The per-app Puma units
  # target /opt/rbenv instead, but these rows have to describe what is running
  # now, not what we intend to run — an adopted row that lies is worse than none.
  LTVB_RUBY_BIN = "/var/www/vhosts/ltvb.nl/.rbenv/versions/3.3.8/bin".freeze
  LTVB_HOME     = "/var/www/vhosts/ltvb.nl".freeze

  def change
    create_table :process_services do |t|
      # Optional: git-ltvb-cable belongs to git.ltvb.nl, but a future host-wide
      # worker would belong to no app at all.
      t.references :app, foreign_key: true

      t.string  :name, null: false            # also the systemd unit name
      t.string  :kind, null: false, default: "generic"

      # An argv ARRAY, never a command string. supervisor's `command=` is a
      # string it splits itself, which puts every value in it one quoting bug
      # away from being a second command; an ExecStart built from a validated
      # array has no shell in it to escape from.
      t.json    :argv, null: false, default: []

      t.string  :user, null: false
      t.string  :working_directory, null: false
      t.json    :environment, null: false, default: {}

      # autostart => comes back after a reboot ([Install] WantedBy=...). Maps
      # directly onto supervisor's autostart=.
      t.boolean :autostart, null: false, default: true
      # managed: false = adopted read-only. The row describes something already
      # configured elsewhere and the manager must not overwrite it.
      t.boolean :managed,   null: false, default: true
      # enabled: false retires a worker without losing its definition, its notes
      # or which app it belonged to.
      t.boolean :enabled,   null: false, default: true

      t.text    :notes

      t.timestamps
    end

    # The name is the unit name; two rows sharing one would race to own a file
    # in /etc/systemd/system.
    add_index :process_services, :name, unique: true

    reversible { |dir| dir.up { adopt_existing_workers! } }
  end

  private

  def adopt_existing_workers!
    rows = adopted_rows.map do |row|
      fqdn = row.delete(:fqdn)
      row.merge(app_id: app_id_for(fqdn), managed: false)
    end
    return if rows.empty?

    process_services.insert_all(rows, record_timestamps: true)
  end

  # Defined inline rather than using ProcessService: a migration has to keep
  # working after the model changes, and this one runs before the model's
  # validations (which reject nothing here, but would still couple the two).
  def process_services
    @process_services ||= Class.new(ActiveRecord::Base) { self.table_name = "process_services" }
  end

  def app_id_for(fqdn)
    subdomain, _, domain = fqdn.to_s.partition(".")
    connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        [ "SELECT id FROM apps WHERE subdomain = ? AND domain = ? LIMIT 1", subdomain, domain ]
      )
    )
  end

  # Transcribed from /etc/systemd/system/*.service and /etc/supervisor/conf.d/*.
  # The three systemd units all start `/bin/bash -lc 'export RBENV_ROOT=...;
  # export PATH=...; exec bundle exec ...'`. That shell exists only to build a
  # PATH, so the argv recorded here is the same process with the PATH stated
  # outright — which is exactly what the unit will say when the row is promoted
  # to managed: true.
  def adopted_rows
    [
      {
        fqdn: "apps.ltvb.nl", name: "ltvb-apps-jobs", kind: "solid_queue",
        user: "ltvb", working_directory: "#{LTVB_HOME}/apps.ltvb.nl",
        argv: [ "#{LTVB_RUBY_BIN}/bundle", "exec", "rails", "solid_queue:start" ],
        environment: rails_env(LTVB_RUBY_BIN),
        autostart: true, enabled: true,
        notes: <<~TXT
          Solid Queue worker for the manager itself (systemd: ltvb-apps-jobs.service).
          DeployRunner restarts this service after a self-deploy — Passenger reloads the
          web process on tmp/restart.txt, but this worker is a separate long-lived
          process still holding the old code.
        TXT
      },
      {
        fqdn: "git.ltvb.nl", name: "git-ltvb-jobs", kind: "solid_queue",
        user: "ltvb", working_directory: "#{LTVB_HOME}/git.ltvb.nl",
        argv: [ "#{LTVB_RUBY_BIN}/bundle", "exec", "rails", "solid_queue:start" ],
        environment: rails_env(LTVB_RUBY_BIN),
        autostart: true, enabled: true,
        notes: <<~TXT
          Solid Queue worker for the GitHub client (systemd: git-ltvb-jobs.service).
          Runs the broadcasts and notifications its webhooks queue.
        TXT
      },
      {
        fqdn: "git.ltvb.nl", name: "git-ltvb-cable", kind: "cable",
        user: "ltvb", working_directory: "#{LTVB_HOME}/git.ltvb.nl",
        argv: [ "#{LTVB_RUBY_BIN}/bundle", "exec", "puma", "-e", "production",
                "-b", "tcp://127.0.0.1:28082", "cable/config.ru" ],
        environment: rails_env(LTVB_RUBY_BIN),
        autostart: true, enabled: true,
        notes: <<~TXT
          Standalone ActionCable Puma for git.ltvb.nl (systemd: git-ltvb-cable.service).
          Apache+Passenger strips the hop-by-hop Connection header from the 101 upgrade
          and browsers reject the response, so /cable is proxied to this dedicated Puma
          on 127.0.0.1:28082 instead. The vhost rule that depends on it is one of the
          four real serving customisations on this box — moving this port breaks the
          websocket silently, with a working page and a dead live view.
        TXT
      },
      {
        fqdn: "music.ltvb.nl", name: "music-solid-queue", kind: "solid_queue",
        user: "ltvb", working_directory: "#{LTVB_HOME}/music.ltvb.nl",
        argv: [ "#{LTVB_RUBY_BIN}/bundle", "exec", "bin/jobs" ],
        environment: rails_env(LTVB_RUBY_BIN),
        autostart: true, enabled: true,
        notes: <<~TXT
          Solid Queue worker, dispatcher and recurring scheduler for music.ltvb.nl
          (supervisor: [program:music-solid-queue], stopwaitsecs=30,
          stdout -> log/solid_queue.log).
        TXT
      },
      {
        fqdn: "mail.ltvb.nl", name: "mail-solid-queue", kind: "solid_queue",
        user: "ltvb", working_directory: "#{LTVB_HOME}/mail.ltvb.nl",
        argv: [ "#{LTVB_RUBY_BIN}/bundle", "exec", "bin/jobs" ],
        environment: rails_env(LTVB_RUBY_BIN),
        autostart: true, enabled: true,
        notes: <<~TXT
          Solid Queue worker for the email app (supervisor: [program:mail-solid-queue],
          stopwaitsecs=30). Runs the every-minute IMAP fetch from config/recurring.yml,
          so a deploy that only touches Passenger leaves stale importer code running
          here until this service is restarted too.
        TXT
      },
      {
        fqdn: "music.ltvb.nl", name: "music-kokoro", kind: "python",
        user: "ltvb", working_directory: "#{LTVB_HOME}/music.ltvb.nl",
        argv: [ "#{LTVB_HOME}/music.ltvb.nl/vendor/kokoro/bin/python", "script/kokoro_server.py" ],
        environment: {
          "HOME"    => LTVB_HOME,
          "HF_HOME" => "#{LTVB_HOME}/music.ltvb.nl/storage/kokoro"
        },
        autostart: true, enabled: true,
        notes: <<~TXT
          Localhost-only Kokoro-82M speech server (supervisor: [program:music-kokoro]).
          Loads its model on boot and needs ~20s before it answers — supervisor gave it
          startsecs=20, so the systemd replacement needs a matching grace period or it
          will be declared failed and restarted forever.
        TXT
      },
      {
        fqdn: "github.lucasvanbriemen.nl", name: "github-laravel-queue", kind: "laravel_queue",
        user: "lucasvanbriemen.nl_p8c08835y9j",
        working_directory: "/var/www/vhosts/lucasvanbriemen.nl/github.lucasvanbriemen.nl",
        argv: [ "/usr/bin/php",
                "/var/www/vhosts/lucasvanbriemen.nl/github.lucasvanbriemen.nl/artisan",
                "queue:work", "--sleep=3", "--tries=3", "--timeout=90" ],
        environment: { "HOME" => "/var/www/vhosts/lucasvanbriemen.nl" },
        autostart: true, enabled: true,
        notes: <<~TXT
          Laravel queue worker for github.lucasvanbriemen.nl.
          supervisor: [program:laravel-queue] in github.conf. Runs as the subscription
          user, never root — it processes untrusted GitHub webhook payloads.
          NOT YET REPRESENTABLE: supervisor runs numprocs=3 with stopasgroup=true. This
          row describes one process; replacing it needs three systemd instances (or a
          template unit) and a KillMode that reaps the forked children.
        TXT
      }
    ]
  end

  # HOME because bundler and rbenv both write there; PATH because the login
  # shell that used to supply it is exactly what these rows exist to remove.
  def rails_env(ruby_bin)
    {
      "HOME"      => LTVB_HOME,
      "RAILS_ENV" => "production",
      "PATH"      => "#{ruby_bin}:/usr/local/bin:/usr/bin:/bin"
    }
  end
end
