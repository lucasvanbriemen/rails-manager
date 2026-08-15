require "test_helper"

class AppTest < ActiveSupport::TestCase
  def build_app(**overrides)
    App.new({
      name: "Example", app_kind: "rails", subdomain: "example", domain: "ltvb.nl",
      ruby_version: "3.3.8", git_repo_url: "git@github.com:x/y.git",
      primary_db_kind: "external"
    }.merge(overrides))
  end

  # The six apex domains among the 22 live hostnames, with the DocumentRoot
  # Apache actually serves them from today (read off the server with
  # `grep DocumentRoot /var/www/vhosts/system/<domain>/conf/httpd.conf`). Four
  # serve the webspace's httpdocs/ directly; two are Laravel and serve its
  # public/. None of them has a <domain>/<domain> directory — that is the whole
  # reason the fqdn cannot be the directory name for an apex site.
  APEX_DOCUMENT_ROOTS = {
    "ltvb.nl"                 => [ "", "/var/www/vhosts/ltvb.nl/httpdocs" ],
    "lucasvanbriemen.nl"      => [ "", "/var/www/vhosts/lucasvanbriemen.nl/httpdocs" ],
    "djtim.eu"                => [ "", "/var/www/vhosts/djtim.eu/httpdocs" ],
    "rijschool-mos.nl"        => [ "", "/var/www/vhosts/rijschool-mos.nl/httpdocs" ],
    "mos-safeguards.com"      => [ "public", "/var/www/vhosts/mos-safeguards.com/httpdocs/public" ],
    "voordezorgmanagement.nl" => [ "public", "/var/www/vhosts/voordezorgmanagement.nl/httpdocs/public" ]
  }.freeze

  # --- apex domains --------------------------------------------------------

  test "an apex domain is its own fqdn" do
    app = build_app(subdomain: nil, domain: "ltvb.nl")
    assert app.apex?
    assert_equal "ltvb.nl", app.fqdn
    assert_equal "https://ltvb.nl/", app.url
    assert_not build_app.apex?
  end

  # End to end for all six: the fqdn is a hostname NginxConfig will accept, the
  # vhost renders, and its `root` is the directory Apache serves today. Before
  # this, every one of them resolved to ".<domain>" and NginxConfig.render raised
  # UnsafeValue — six live sites the manager could not describe at all.
  test "every apex domain renders a vhost rooted where the server serves it today" do
    APEX_DOCUMENT_ROOTS.each do |domain, (suffix, document_root)|
      app = build_app(subdomain: nil, domain: domain, doc_root_suffix: suffix,
                      apex_confirmed: true)

      assert app.valid?, "#{domain}: #{app.errors.full_messages.to_sentence}"
      assert_nil app.undeployable_reason, domain
      assert_equal "/var/www/vhosts/#{domain}/httpdocs", app.app_path, domain
      assert_equal document_root, app.public_path, domain
      assert_equal [ "httpdocs", suffix ].reject(&:empty?).join("/"), app.relative_www_root, domain

      conf = NginxConfig.render(app)
      assert_match "server_name #{domain};", conf
      assert_match "root #{document_root};", conf
    end
  end

  # A half-filled record used to produce ".ltvb.nl", which reads like a wildcard
  # and is not a hostname — nginx refuses to render it, and app_path pointed at
  # a dotfile in the shared webspace root.
  test "a half-filled hostname never produces a leading dot" do
    assert_equal "example", build_app(domain: nil).fqdn
    assert_equal "", build_app(subdomain: nil, domain: nil).fqdn
  end

  # A blank subdomain is allowed — an apex site has none. A blank domain is not:
  # it names the webspace, and without it there is no directory to resolve.
  # (Valid is not the same as deployable; see the deploy-safety tests below.)
  test "an apex app is valid without a subdomain, but never without a domain" do
    assert build_app(subdomain: nil).valid?
    assert_not build_app(subdomain: nil, domain: nil).valid?
  end

  # --- document root -------------------------------------------------------

  test "rails and laravel serve from public/" do
    assert_equal "/var/www/vhosts/ltvb.nl/example.ltvb.nl/public",
                 build_app.public_path
    assert_equal "example.ltvb.nl/public", build_app.relative_www_root
  end

  # Pointing a plain-PHP or static site at a non-existent public/ is the exact
  # misconfiguration that took git.ltvb.nl down, so the suffix is per-app data.
  test "a static site serves from the app root, not public/" do
    app = build_app(app_kind: "static", doc_root_suffix: "", ruby_version: nil)
    assert_equal "/var/www/vhosts/ltvb.nl/example.ltvb.nl", app.public_path
    assert_equal "example.ltvb.nl", app.relative_www_root
  end

  test "a custom suffix is honoured" do
    app = build_app(app_kind: "php", doc_root_suffix: "httpdocs", ruby_version: nil, php_version: "8.3")
    assert_equal "/var/www/vhosts/ltvb.nl/example.ltvb.nl/httpdocs", app.public_path
  end

  # --- kind predicates -----------------------------------------------------

  test "kind predicates group the runtimes correctly" do
    assert build_app(app_kind: "rails").ruby?
    assert_not build_app(app_kind: "laravel", ruby_version: nil, php_version: "8.3").ruby?

    assert build_app(app_kind: "laravel", ruby_version: nil, php_version: "8.3").php?
    assert build_app(app_kind: "cron", ruby_version: nil, php_version: "8.3").php?
    assert_not build_app(app_kind: "static", ruby_version: nil).php?
  end

  test "cron apps and repos are not served over http" do
    assert build_app.served?
    assert_not build_app(app_kind: "cron", ruby_version: nil, php_version: "8.3").served?
    assert_not build_app(app_kind: "repo", deploy_path: "/srv/x", ruby_version: nil).served?
  end

  test "a served app can still be marked as not serving http" do
    assert_not build_app(serves_http: false).served?
  end

  # --- validations ---------------------------------------------------------

  test "a served app requires a domain" do
    assert_not build_app(domain: nil).valid?
  end

  test "a cron app needs no hostname" do
    app = build_app(app_kind: "cron", subdomain: nil, domain: nil,
                    ruby_version: nil, php_version: "8.3")
    assert app.valid?, app.errors.full_messages.to_sentence
  end

  test "ruby version is required only for ruby kinds" do
    assert_not build_app(ruby_version: nil).valid?
    assert build_app(app_kind: "static", ruby_version: nil).valid?
  end

  test "php version is required only for php kinds" do
    assert_not build_app(app_kind: "laravel", ruby_version: nil, php_version: nil).valid?
    assert build_app(app_kind: "laravel", ruby_version: nil, php_version: "8.3").valid?
  end

  # --- ip allowlist --------------------------------------------------------
  # These entries are interpolated into a web-server config that root parses.

  test "accepts addresses and CIDR blocks" do
    app = build_app(ip_allowlist: "62.194.231.108 2001:1c00:9501:6700::/64 127.0.0.1 ::1")
    assert app.valid?, app.errors.full_messages.to_sentence
    assert_equal 4, app.ip_allowlist_entries.size
  end

  test "rejects hostnames and free text in the allowlist" do
    assert_not build_app(ip_allowlist: "example.com").valid?
    assert_not build_app(ip_allowlist: "127.0.0.1; deny all").valid?
    assert_not build_app(ip_allowlist: "10.0.0.1\nallow all").valid?
  end

  test "rejects a nonsense prefix length" do
    assert_not build_app(ip_allowlist: "10.0.0.0/abc").valid?
  end

  # --- deploy safety -------------------------------------------------------

  test "deploy_user defaults to ltvb but honours the webspace owner" do
    assert_equal "ltvb", build_app.deploy_user
    assert_equal "lucasvanbriemen.nl_p8c08835y9j",
                 build_app(runtime_user: "lucasvanbriemen.nl_p8c08835y9j").deploy_user
  end

  # The guard exists because the deploy runner does `git reset --hard` in
  # app_path: a record whose path is not unambiguously its own directory must
  # never reach the filesystem. Apex support widens what "its own directory"
  # means, so both halves are tested — the apex site deploys, the broken row
  # still does not.

  # An apex site and a subdomain app whose subdomain was wiped are the same row,
  # and both resolve to the webspace's httpdocs/ — so the confirmation flag, not
  # the blank subdomain, is what authorises writing there.
  test "a confirmed apex site is deployable — httpdocs is its own directory" do
    assert_nil build_app(subdomain: nil, domain: "ltvb.nl", apex_confirmed: true).undeployable_reason
  end

  test "an unconfirmed blank subdomain is still refused a deploy" do
    app = build_app
    app.subdomain = nil
    assert_match(/apex site's files/, app.undeployable_reason)
    assert_match(/httpdocs/, app.undeployable_reason)
  end

  test "the confirmation has to agree with the rest of the record" do
    assert_not build_app(apex_confirmed: true).valid?
    assert_not build_app(app_kind: "cron", ruby_version: nil, php_version: "8.3",
                         subdomain: nil, apex_confirmed: true).valid?
    assert build_app(subdomain: nil, apex_confirmed: true).valid?
  end

  test "an app with no domain is refused a deploy" do
    # app_path would be "/var/www/vhosts//…" — inside the shared webspace root
    # that eight internet-facing apps live in.
    app = build_app
    app.domain = nil
    assert_match(/missing domain/, app.undeployable_reason)
  end

  # A cron app never gets a vhost, so nothing serves a domain out of httpdocs/
  # for it: a blank subdomain there is a broken row pointing at the apex site's
  # files, not an apex app. Same for anything else without a vhost.
  test "a blank subdomain on a kind that has no vhost is refused a deploy" do
    app = build_app(app_kind: "cron", ruby_version: nil, php_version: "8.3",
                    subdomain: nil, apex_confirmed: true)
    assert_match(/no vhost/, app.undeployable_reason)

    assert_nil build_app(app_kind: "laravel", ruby_version: nil, php_version: "8.3",
                         subdomain: nil, apex_confirmed: true).undeployable_reason
  end

  # update_column and a legacy row both skip every validation, so the guard
  # checks the resolved directory rather than trusting the columns.
  test "a hostname that is not a plain directory name is refused a deploy" do
    app = build_app
    app.domain = "ltvb.nl/../.."
    assert_match(/not a plain directory name/, app.undeployable_reason)

    # The apex app's own directory is the constant "httpdocs", so its domain is
    # the segment that has to be checked.
    app = build_app(subdomain: nil, apex_confirmed: true)
    app.domain = ".."
    assert_match(/not a plain directory name/, app.undeployable_reason)
    assert_equal "/var/www/vhosts/../httpdocs", app.app_path
  end

  test "a repo without a checkout path is refused a deploy" do
    assert_match(/no checkout path/,
                 build_app(app_kind: "repo", ruby_version: nil, deploy_path: nil).undeployable_reason)
  end

  # Clearing a subdomain silently re-points an app at ANOTHER app's populated
  # directory (the apex site's httpdocs/). The edit is refused unless the same
  # edit also confirms the apex domain, so the two signals cannot drift apart.
  test "an existing site is not turned into the apex site by clearing its subdomain alone" do
    app = App.create!(name: "Git", app_kind: "rails", subdomain: "git", domain: "ltvb.nl",
                      git_repo_url: "git@github.com:lucas/git.git", primary_db_kind: "sqlite")

    assert_not app.update(subdomain: "")
    assert_match(/cannot be cleared/, app.errors[:subdomain].to_sentence)
    assert_equal "/var/www/vhosts/ltvb.nl/git.ltvb.nl", app.reload.app_path

    assert app.update(subdomain: "", apex_confirmed: true), app.errors.full_messages.to_sentence
    assert_equal "/var/www/vhosts/ltvb.nl/httpdocs", app.app_path
  end

  test "the apex site is created as its own record" do
    app = App.new(name: "ltvb.nl", app_kind: "static", subdomain: nil, domain: "ltvb.nl",
                  doc_root_suffix: "", apex_confirmed: true,
                  git_repo_url: "git@github.com:lucas/ltvb.git", primary_db_kind: "external")
    assert app.save, app.errors.full_messages.to_sentence
    assert_equal "/var/www/vhosts/ltvb.nl/httpdocs", app.app_path
    assert_nil app.undeployable_reason
  end

  # --- serving customisations ----------------------------------------------
  # NginxConfig branches on all five of these but reads them defensively, so
  # while they were not columns every vhost rendered as if the app had none of
  # them — no /cable, no X-Accel, a forced :80 redirect and no default vhost.
  # These tests render the real templates: they fail if a column disappears.

  test "the cable endpoint reaches the rendered vhost" do
    conf = NginxConfig.render(build_app(subdomain: "git", cable_path: "/cable", cable_port: 28082))

    assert_match "location /cable {", conf
    assert_match "proxy_pass http://127.0.0.1:28082;", conf
  end

  test "an app that cables from its own process gets its own socket" do
    conf = NginxConfig.render(build_app(cable_path: "/cable"))

    assert_match "location /cable {", conf
    assert_match "proxy_pass http://unix:/run/ltvb-app/example.ltvb.nl/puma.sock:;", conf
  end

  test "the x-accel directory reaches the rendered vhost" do
    app = build_app(subdomain: "music", app_kind: "laravel", ruby_version: nil, php_version: "8.3",
                    xaccel_path: "/var/www/vhosts/ltvb.nl/music.ltvb.nl/storage/audio")

    assert_match "alias /var/www/vhosts/ltvb.nl/music.ltvb.nl/storage/audio/;",
                 NginxConfig.render(app)
  end

  test "http redirects by default and serves the site when the app opts out" do
    assert_match "return 301 https://$host$request_uri;", NginxConfig.render(build_app)
    assert_no_match(/return 301 https/, NginxConfig.render(build_app(redirect_http: false)))
  end

  test "only the default vhost claims unmatched requests" do
    assert_match "listen 443 default_server ssl;", NginxConfig.render(build_app(default_server: true))
    assert_no_match(/default_server/, NginxConfig.render(build_app))
  end

  # lucasvanbriemen.nl, end to end: the apex site, the IPv4 default vhost, HSTS,
  # and content that is served over plain http today.
  test "the apex default vhost renders against the directory it really serves" do
    app = build_app(name: "lucasvanbriemen.nl", subdomain: nil, domain: "lucasvanbriemen.nl",
                    doc_root_suffix: "", default_server: true, hsts: true, redirect_http: false)
    conf = NginxConfig.render(app)

    assert_match "server_name lucasvanbriemen.nl;", conf
    assert_match "root /var/www/vhosts/lucasvanbriemen.nl/httpdocs;", conf
    assert_match "listen 80 default_server;", conf
    assert_match "listen [::]:443 default_server ssl;", conf
    assert_match "/etc/letsencrypt/live/lucasvanbriemen.nl/fullchain.pem;", conf
    assert_match "Strict-Transport-Security", conf
    assert_no_match(/return 301 https/, conf)
  end

  test "serving fields are validated before they can reach an nginx config" do
    assert_not build_app(cable_path: "/cable; return 500").valid?
    assert_not build_app(cable_path: "cable").valid?
    assert_not build_app(cable_port: 0).valid?
    assert_not build_app(cable_port: 70_000).valid?
    assert_not build_app(xaccel_path: "/srv/audio; deny all").valid?
    assert_not build_app(xaccel_path: "/srv/../../etc").valid?
    assert_not build_app(xaccel_path: "storage/audio").valid?
    assert_not build_app(doc_root_suffix: "/public").valid?
    assert_not build_app(doc_root_suffix: "../../etc").valid?

    assert build_app(cable_path: "/cable", cable_port: 28082,
                     xaccel_path: "/var/www/vhosts/ltvb.nl/music.ltvb.nl/storage/audio",
                     doc_root_suffix: "public").valid?
  end

  test "health check url is built from the configured path" do
    assert_equal "https://example.ltvb.nl/up", build_app(health_check_path: "/up").health_check_url
    assert_equal "https://example.ltvb.nl/", build_app(health_check_path: "/").health_check_url
  end
end
