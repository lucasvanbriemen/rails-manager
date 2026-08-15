# Lets the manager represent every app on the server, not just the Rails ones.
# The 22 live hostnames break down as 6 Rails, 5 Laravel, 4 plain PHP, 4 static,
# 2 webmail and 3 cron-only Laravel apps with no vhost at all.
#
# Every column is additive with a default that preserves the behaviour of the
# 7 existing rows, so this migration changes nothing that is already running.
class WidenAppKinds < ActiveRecord::Migration[8.0]
  def change
    # Which runtime serves it. Existing rows are Rails and stay Rails.
    add_column :apps, :php_version, :string

    # The system user that owns the checkout and runs the app. Only ltvb.nl's
    # apps run as `ltvb`; the other five subscriptions each have their own uid,
    # and a deploy has to run as the right one or it writes root-owned files
    # into someone else's webspace.
    add_column :apps, :runtime_user, :string

    # Where the served files are, relative to the app root. Rails and Laravel
    # serve from "public"; plain PHP and static sites serve from the root.
    # This is the setting whose default caused the original git.ltvb.nl outage.
    add_column :apps, :doc_root_suffix, :string, default: "public", null: false

    # Path that must answer 2xx/3xx for a deploy to be considered healthy.
    # Rails apps have /up; a Laravel or static site usually only has /.
    add_column :apps, :health_check_path, :string, default: "/", null: false

    # Serving customisations that live only in hand-written Apache vhost files
    # today and would be silently lost by a template-driven rebuild.
    add_column :apps, :ip_allowlist, :string   # space-separated CIDRs/addresses
    add_column :apps, :hsts, :boolean, default: false, null: false

    # Apps with no hostname at all (cron-only Laravel) still need tracking:
    # they have code, a database and a schedule, they just never serve HTTP.
    add_column :apps, :serves_http, :boolean, default: true, null: false

    # Retired apps stay in the table so their history survives, but drop out of
    # the dashboard and are never deployed or health-checked.
    add_column :apps, :archived_at, :datetime
    add_index  :apps, :archived_at

    # Rails apps read /up; everything else was created before health checks
    # existed, so give the existing rows the endpoint they actually have.
    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE apps SET health_check_path = '/up', runtime_user = 'ltvb'
          WHERE app_kind = 'rails'
        SQL
        execute <<~SQL
          UPDATE apps SET doc_root_suffix = '', serves_http = 0, health_check_path = '/'
          WHERE app_kind = 'repo'
        SQL
      end
    end
  end
end
