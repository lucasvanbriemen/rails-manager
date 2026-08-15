# The serving customisations the real vhosts have and the manager could not
# express. NginxConfig already branches on all five names, but reads them
# defensively (App#respond_to?), so until they are columns every site renders as
# if it had none of them — silently, with a config nginx happily loads:
#
#   git.ltvb.nl        no /cable location   -> the websocket 404s
#   music.ltvb.nl      no X-Accel path      -> every download 404s
#   ai/components/github.lucasvanbriemen.nl and lucasvanbriemen.nl
#                      forced :80 -> :443   -> content that is served over http
#                                              today starts redirecting
#   lucasvanbriemen.nl not the default vhost-> unmatched SNI lands on whichever
#                                              server block nginx read first
#
# Defaults preserve today's rendering for every other row: redirect_http is on
# (forgetting to redirect is the failure that matters) and default_server is off
# (exactly one vhost may claim it per address family).
#
# The sixth column, apex_confirmed, is not read by NginxConfig at all — it is
# what lets App tell the six apex sites apart from a row that lost its
# subdomain, now that both are representable. See below.
class AddServingFieldsToApps < ActiveRecord::Migration[8.0]
  def change
    # ActionCable endpoint. A path rather than a boolean because it is written
    # into nginx as a `location` prefix, and a port because git.ltvb.nl runs
    # cable as a separate standalone Puma on loopback rather than in the web
    # process — an app that cables from its own process leaves the port blank
    # and gets its own unix socket.
    add_column :apps, :cable_path, :string
    add_column :apps, :cable_port, :integer

    # Apache's XSendFilePath, ported to X-Accel-Redirect. The directory an app
    # is allowed to hand out files from.
    add_column :apps, :xaccel_path, :string

    # Whether :80 redirects to :443 or serves the site.
    add_column :apps, :redirect_http, :boolean, default: true, null: false

    # Where unmatched SNI lands. Apache made lucasvanbriemen.nl the IPv4 default.
    add_column :apps, :default_server, :boolean, default: false, null: false

    # A blank subdomain is what the six apex sites look like — and also what
    # git.ltvb.nl looks like the instant someone wipes its subdomain. Both
    # resolve to the webspace's httpdocs/, so the *paths* follow from the blank
    # subdomain alone (an imported apex row reads its real logs and renders its
    # real document root straight away). WRITING there is what needs a second
    # signal: this flag is the operator confirming the blank subdomain is
    # deliberate, and without it the deploy runner refuses to `git reset --hard`
    # over what is, on every one of these domains, another live site's files.
    # Default false, so no existing row and no import becomes deployable by
    # accident.
    add_column :apps, :apex_confirmed, :boolean, default: false, null: false

    reversible do |dir|
      dir.up { backfill_live_customisations }
    end
  end

  private

  # The four customisations that exist on the running server, read off its
  # Apache vhosts. Plain UPDATEs keyed on the hostname: they match nothing on a
  # dev or test database (where these apps have not been imported yet) and
  # nothing on a server where the rows have not been created, so the migration
  # is a no-op rather than an error in both cases. Booleans are 1/0 because the
  # database is SQLite.
  def backfill_live_customisations
    execute <<~SQL.squish
      UPDATE apps SET cable_path = '/cable', cable_port = 28082
      WHERE subdomain = 'git' AND domain = 'ltvb.nl'
    SQL

    execute <<~SQL.squish
      UPDATE apps SET xaccel_path = '/var/www/vhosts/ltvb.nl/music.ltvb.nl/storage/audio'
      WHERE subdomain = 'music' AND domain = 'ltvb.nl'
    SQL

    # The apex row has no subdomain at all — matched on IS NULL as well as ''
    # because a row imported before subdomains were normalised may hold either.
    # apex_confirmed is deliberately NOT set here: a migration cannot tell this
    # row apart from a subdomain app whose subdomain was wiped, and confirming
    # it is what authorises writing over the site's files. An operator ticks it.
    execute <<~SQL.squish
      UPDATE apps SET default_server = 1, hsts = 1, redirect_http = 0
      WHERE domain = 'lucasvanbriemen.nl' AND (subdomain IS NULL OR subdomain = '')
    SQL

    execute <<~SQL.squish
      UPDATE apps SET redirect_http = 0
      WHERE domain = 'lucasvanbriemen.nl' AND subdomain IN ('ai', 'components', 'github')
    SQL
  end
end
