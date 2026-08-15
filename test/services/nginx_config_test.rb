require "test_helper"
require "tmpdir"

# The rendered file is read by root. These tests treat the App record as hostile
# input, because anyone who can edit an app can otherwise write nginx directives
# that run with full privilege.
#
# NginxConfig does not own the config text — it renders the agent's template, the
# one the agent uses to write the file nginx actually serves. So these assertions
# are about the served config, not about a second opinion of it; the test that
# holds the two renderers to the same bytes lives in agent_protocol_test.rb,
# which is the file that can load the daemon.
class NginxConfigTest < ActiveSupport::TestCase
  # Values that each terminate a directive, open/close a block, start a comment,
  # or split one argument into two. Every field is fed all of them.
  INJECTIONS = [
    "evil; return 500",
    "evil\nreturn 500",
    "evil\r\nreturn 500",
    "evil}\nserver { listen 80",
    "evil{",
    "evil # comment",
    "evil $document_root",
    "evil'quote",
    'evil"quote',
    "evil\\escape",
    "evil with space",
    "evil\tTAB",
    "evil`backtick"
  ].freeze

  # ---- validators ----------------------------------------------------------

  test "safe! rejects every character that could inject a directive" do
    INJECTIONS.each do |value|
      assert_raises(NginxConfig::UnsafeValue, "accepted #{value.inspect}") do
        NginxConfig.safe!(value, field: "test")
      end
    end
  end

  test "safe! rejects blank, over-long and non-ASCII values" do
    assert_raises(NginxConfig::UnsafeValue) { NginxConfig.safe!("", field: "test") }
    assert_raises(NginxConfig::UnsafeValue) { NginxConfig.safe!(nil, field: "test") }
    assert_raises(NginxConfig::UnsafeValue) { NginxConfig.safe!("a" * 256, field: "test") }
    # Homoglyphs read as a legitimate hostname in a diff but are not one.
    assert_raises(NginxConfig::UnsafeValue) { NginxConfig.safe!("gіt.ltvb.nl", field: "test") }
  end

  test "safe! accepts ordinary single-token values" do
    assert_equal "git.ltvb.nl", NginxConfig.safe!("git.ltvb.nl", field: "test")
    assert_equal "/var/www/a-b_c.d", NginxConfig.safe!("/var/www/a-b_c.d", field: "test")
  end

  test "safe_fqdn! requires a dotted lowercase hostname" do
    assert_equal "git.ltvb.nl", NginxConfig.safe_fqdn!("git.ltvb.nl")

    [ "ltvb", ".ltvb.nl", "git..ltvb.nl", "-git.ltvb.nl", "git-.ltvb.nl",
      "GIT.ltvb.nl", "git.ltvb.nl.", "*.ltvb.nl", "1.2.3.4:80" ].each do |value|
      assert_raises(NginxConfig::UnsafeValue, "accepted #{value.inspect}") { NginxConfig.safe_fqdn!(value) }
    end
  end

  test "safe_path! rejects relative paths and .. segments" do
    assert_equal "/var/www/vhosts/ltvb.nl/git.ltvb.nl/public",
                 NginxConfig.safe_path!("/var/www/vhosts/ltvb.nl/git.ltvb.nl/public", field: "root")

    [ "var/www", "./var", "/var/../../etc", "/var/www/..", "/..", "/var/www/%2e%2e" ].each do |value|
      assert_raises(NginxConfig::UnsafeValue, "accepted #{value.inspect}") do
        NginxConfig.safe_path!(value, field: "root")
      end
    end
  end

  test "safe_path! allows a leading .. only as part of a name" do
    # "..foo" is a legal directory name; only a whole ".." segment escapes.
    assert_equal "/var/www/..foo", NginxConfig.safe_path!("/var/www/..foo", field: "root")
  end

  test "safe_uri_path! rejects regex metacharacters and location modifiers" do
    assert_equal "/cable", NginxConfig.safe_uri_path!("/cable", field: "cable_path")

    [ "cable", "~ /cable", "/cable?x=1", "/cable*", "/(cable)", "/cable|/admin", "/../cable" ].each do |value|
      assert_raises(NginxConfig::UnsafeValue, "accepted #{value.inspect}") do
        NginxConfig.safe_uri_path!(value, field: "cable_path")
      end
    end
  end

  test "safe_ip! accepts addresses and CIDR blocks and rejects everything else" do
    %w[62.194.231.108 127.0.0.1 ::1 2001:1c00:9501:6700::/64 10.0.0.0/8].each do |value|
      assert_equal value, NginxConfig.safe_ip!(value)
    end

    # A hostname would make nginx resolve at load time and quietly allow
    # whatever that name points at afterwards.
    [ "office.example.com", "all", "1.2.3.4; return 500", "1.2.3.4/8/8", "1.2.3.4/999",
      "1.2.3.4/x", "999.1.1.1", "" ].each do |value|
      assert_raises(NginxConfig::UnsafeValue, "accepted #{value.inspect}") { NginxConfig.safe_ip!(value) }
    end
  end

  test "safe_port! accepts a port number and rejects anything else" do
    assert_equal 28_082, NginxConfig.safe_port!("28082", field: "cable_port")
    assert_equal 28_082, NginxConfig.safe_port!(28_082, field: "cable_port")

    [ "0", "65536", "-1", "80;", "80 90", "eighty", "", nil, "0x50" ].each do |value|
      assert_raises(NginxConfig::UnsafeValue, "accepted #{value.inspect}") do
        NginxConfig.safe_port!(value, field: "cable_port")
      end
    end
  end

  # ---- the template this class renders -------------------------------------
  #
  # It is the agent's file, not this checkout's, and the agent writes the config
  # that is actually served. That is the whole point of the consolidation, so the
  # rules that decide WHICH file gets read are part of the trust boundary too.

  test "the template directory is the agent's own, so a preview reads the file the agent writes" do
    assert_equal "/etc/ltvb/agent/templates", NginxConfig::TEMPLATE_DIR.to_s
  end

  test "a template that is not a plain root-owned file is refused rather than rendered" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "nginx-site.erb")
      File.write(path, "server {}\n")
      File.chmod(0o644, path)

      # Owned by whoever runs the suite, which is not root — the check this
      # class exists for, since the checkout is owned by the uid eight
      # internet-facing apps share.
      assert_raises(NginxConfig::UnsafeValue) { NginxConfig.trusted_template!(Pathname.new(path)) }

      link = File.join(dir, "linked.erb")
      File.symlink(path, link)
      # lstat, not stat: the symlink is the thing an attacker gets to plant.
      assert_raises(NginxConfig::UnsafeValue) { NginxConfig.trusted_template!(Pathname.new(link)) }

      assert_raises(NginxConfig::UnsafeValue) { NginxConfig.trusted_template!(Pathname.new(File.join(dir, "gone.erb"))) }
    end
  end

  # ---- injection through the model -----------------------------------------

  test "a hostile subdomain or domain is rejected instead of rendered" do
    INJECTIONS.each do |value|
      assert_raises(NginxConfig::UnsafeValue, "subdomain #{value.inspect} rendered") do
        NginxConfig.render(build_app(subdomain: value))
      end
      assert_raises(NginxConfig::UnsafeValue, "domain #{value.inspect} rendered") do
        NginxConfig.render(build_app(domain: value))
      end
    end
  end

  test "a hostile document root suffix is rejected" do
    INJECTIONS.each do |value|
      assert_raises(NginxConfig::UnsafeValue, "doc_root_suffix #{value.inspect} rendered") do
        NginxConfig.render(build_app(doc_root_suffix: value))
      end
    end

    # The suffix is joined onto the app path, so this is the interesting one:
    # it needs no punctuation at all to escape the webspace.
    assert_raises(NginxConfig::UnsafeValue) do
      NginxConfig.render(build_app(doc_root_suffix: "../../../../etc"))
    end
  end

  test "a hostile ip allowlist is rejected even when the model validation was bypassed" do
    assert_raises(NginxConfig::UnsafeValue) do
      NginxConfig.render(build_app(ip_allowlist: "127.0.0.1 1.2.3.4;deny all"))
    end
    assert_raises(NginxConfig::UnsafeValue) do
      NginxConfig.render(build_app(ip_allowlist: "office.example.com"))
    end
  end

  test "hostile cable, xaccel and port fields are rejected" do
    INJECTIONS.each do |value|
      assert_raises(NginxConfig::UnsafeValue, "cable_path #{value.inspect} rendered") do
        NginxConfig.render(build_app(cable_path: value))
      end
      assert_raises(NginxConfig::UnsafeValue, "xaccel_path #{value.inspect} rendered") do
        NginxConfig.render(build_app(xaccel_path: value))
      end
      assert_raises(NginxConfig::UnsafeValue, "cable_port #{value.inspect} rendered") do
        NginxConfig.render(build_app(cable_port: value))
      end
    end

    assert_raises(NginxConfig::UnsafeValue) do
      NginxConfig.render(build_app(xaccel_path: "/var/www/../../etc/letsencrypt"))
    end
  end

  test "app_kind cannot be used to reach a template outside the template directory" do
    [ "../../../../etc/passwd", "../server", "rails/../rails", "cron", "repo", "" ].each do |kind|
      assert_raises(NginxConfig::UnsafeValue, "rendered kind #{kind.inspect}") do
        NginxConfig.render(build_app(app_kind: kind))
      end
    end
  end

  # nginx tries regex locations in the order they are written and takes the
  # first that matches, so this is a fact about position, not about presence —
  # `/uploads/.env.php` matches both, and the wrong order serves it to FPM.
  test "the dotfile deny is written before the php handler, not merely present" do
    config = NginxConfig.render(build_app(app_kind: "laravel"))

    dotfiles = config.index("location ~ /\\.(?!well-known/) {")
    php      = config.index("location ~ [^/]\\.php(/|$) {")
    assert dotfiles, "no dotfile deny"
    assert php, "no php handler"
    assert dotfiles < php, "the php handler is ordered before the dotfile deny"
  end

  # The challenge path is literally a dotfile directory, so the deny above would
  # swallow it — `^~` on a prefix location is what stops nginx from ever
  # reaching the regexes. Losing this 403s every http-01 renewal for 20 sites
  # about thirty days later.
  test "the acme challenge location is exempt from the dotfile deny" do
    config = NginxConfig.render(build_app(app_kind: "static"))

    assert_includes config, "location ^~ /.well-known/acme-challenge/ {"
    assert_equal 2, config.scan("location ^~ /.well-known/acme-challenge/ {").length
  end

  test "validation happens before any rendering so a bad record produces no partial config" do
    app = build_app(ip_allowlist: "not-an-ip")
    # If the templates validated lazily, this would have already written a
    # truncated server block by the time it raised — and a truncated block stops
    # nginx from loading at all, for every site on the box.
    error = assert_raises(NginxConfig::UnsafeValue) { NginxConfig.render(app) }
    assert_match(/ip_allowlist/, error.message)
  end

  # ---- app kinds -----------------------------------------------------------

  test "rails proxies to its own unix socket and serves static files first" do
    config = NginxConfig.render(build_app(app_kind: "rails", subdomain: "git"))

    assert_includes config, "proxy_pass http://unix:/run/ltvb-app/git.ltvb.nl/puma.sock:;"
    assert_includes config, "try_files $uri @app;"
    assert_includes config, "proxy_set_header X-Forwarded-Proto $scheme;"
    assert_not_includes config, "fastcgi_pass"
    assert_structurally_valid config
  end

  test "the socket nginx proxies to is the one the systemd unit creates" do
    # Two services independently derive this path. A mismatch is a 502 on every
    # Rails site, and neither service's own tests would notice.
    app = build_app(subdomain: "git")
    assert_includes NginxConfig.render(app), "proxy_pass http://unix:#{SystemdUnit.app_socket_path(app)}:;"
  end

  test "laravel reproduces the .htaccess front controller and talks to the plesk pool" do
    config = NginxConfig.render(build_app(app_kind: "laravel", subdomain: "music"))

    assert_includes config, "try_files $uri $uri/ /index.php?$query_string;"
    assert_includes config, "fastcgi_pass unix:/var/www/vhosts/system/music.ltvb.nl/php-fpm.sock;"
    assert_not_includes config, "proxy_pass"
    assert_structurally_valid config
  end

  test "plain php gets fpm but no front controller" do
    config = NginxConfig.render(build_app(app_kind: "php", subdomain: "aio"))

    assert_includes config, "try_files $uri $uri/ =404;"
    assert_not_includes config, "/index.php?$query_string"
    assert_includes config, "fastcgi_pass unix:/var/www/vhosts/system/aio.ltvb.nl/php-fpm.sock;"
    assert_structurally_valid config
  end

  test "static serves files only and refuses to hand a .php file to anything" do
    config = NginxConfig.render(build_app(app_kind: "static", subdomain: "senne", doc_root_suffix: ""))

    assert_no_match(/^\s*fastcgi_pass/, config)
    assert_no_match(/^\s*proxy_pass/, config)
    # Not merely "unhandled": without this the source of a stray script would be
    # served as text/plain.
    assert_includes config, "location ~ [^/]\\.php(/|$) {\n        return 404;"
    assert_includes config, "root /var/www/vhosts/ltvb.nl/senne.ltvb.nl;"
    assert_structurally_valid config
  end

  test "the php handler refuses to execute a script that is not a real file" do
    config = NginxConfig.render(build_app(app_kind: "laravel"))

    # /uploads/photo.jpg/shell.php would otherwise reach FPM with a
    # SCRIPT_FILENAME that resolves to the uploaded image.
    assert_includes config, "try_files $fastcgi_script_name =404;"
    # try_files clears $fastcgi_path_info, so PATH_INFO must come from a copy.
    assert_includes config, "set $ltvb_path_info $fastcgi_path_info;"
    assert_includes config, "fastcgi_param PATH_INFO         $ltvb_path_info;"
  end

  # ---- the four real customisations ----------------------------------------

  test "cable_path renders a websocket location pointed at the standalone cable server" do
    config = NginxConfig.render(build_app(subdomain: "git", cable_path: "/cable", cable_port: 28_082))

    assert_includes config, "location /cable {"
    assert_includes config, "proxy_pass http://127.0.0.1:28082;"
    assert_includes config, "proxy_set_header Upgrade    $http_upgrade;"
    assert_includes config, "proxy_set_header Connection $ltvb_connection_upgrade;"
    # An idle websocket must not be culled by the 60s proxy_read_timeout default.
    assert_includes config, "proxy_read_timeout 3600s;"
  end

  test "cable_path without a port cables to the app's own socket" do
    config = NginxConfig.render(build_app(subdomain: "git", cable_path: "/cable"))

    assert_includes config, "location /cable {"
    assert_includes config, "proxy_pass http://unix:/run/ltvb-app/git.ltvb.nl/puma.sock:;"
  end

  test "no cable_path renders no websocket location at all" do
    config = NginxConfig.render(build_app(subdomain: "git"))

    assert_not_includes config, "$http_upgrade"
    assert_not_includes config, "$ltvb_connection_upgrade"
  end

  test "ip_allowlist renders allow/deny and always exempts the acme challenge" do
    config = NginxConfig.render(build_app(
      subdomain: "login",
      ip_allowlist: "62.194.231.108 2001:1c00:9501:6700::/64 93.184.105.110 87.106.231.214 127.0.0.1 ::1"
    ))

    assert_includes config, "allow 62.194.231.108;"
    assert_includes config, "allow 2001:1c00:9501:6700::/64;"
    assert_includes config, "allow ::1;"
    # Both server blocks: renewal must survive whichever one certbot reaches.
    assert_equal 2, config.scan("location ^~ /.well-known/acme-challenge/ {").length
    # Server level (four spaces) in each block; the deeper `deny all` belongs to
    # the dotfile location and is not the allowlist.
    assert_equal 2, config.scan(/^ {4}deny all;$/).length
    assert_equal 2, config.scan("allow all;").length # the acme exemption, x2
    assert_structurally_valid config
  end

  test "an app with no allowlist renders no allow or deny at server level" do
    config = NginxConfig.render(build_app)

    assert_no_match(/^ {4}deny all;$/, config)
    assert_no_match(/^ {4}allow /, config)
    # The acme exemption is only meaningful next to a restriction; the dotfile
    # deny is a location of its own and must survive.
    assert_includes config, "location ~ /\\.(?!well-known/) {"
  end

  test "xaccel_path renders an internal alias, not a filesystem-path header" do
    config = NginxConfig.render(build_app(
      subdomain: "music", app_kind: "laravel",
      xaccel_path: "/var/www/vhosts/ltvb.nl/music.ltvb.nl/storage/audio"
    ))

    assert_includes config, "location /_x-accel/ {"
    assert_includes config, "internal;"
    # Trailing slash: without it nginx concatenates rather than substitutes and
    # /_x-accel/a.mp3 resolves to .../audioa.mp3.
    assert_includes config, "alias /var/www/vhosts/ltvb.nl/music.ltvb.nl/storage/audio/;"
  end

  test "hsts is sent on https only, and never from the staging ports" do
    app  = build_app(subdomain: "lucasvanbriemen", domain: "lucasvanbriemen.nl", hsts: true)
    live = NginxConfig.render(app)

    http_block, https_block = live.split(/^server \{$/).last(2)
    assert_not_includes http_block, "Strict-Transport-Security"
    assert_includes https_block, "add_header Strict-Transport-Security " \
                                 "\"max-age=15768000; includeSubDomains\" always;"

    # Staging shares the hostname with live and HSTS is scoped to the host, not
    # the port, so a header from :9443 would pin the browser for the real site.
    assert_not_includes NginxConfig.render(app, staging: true), "Strict-Transport-Security"
  end

  test "hsts is not dropped by a location that sets its own headers" do
    config = NginxConfig.render(build_app(hsts: true))

    # nginx replaces, rather than merges, the inherited add_header set as soon as
    # a location declares one of its own — so every add_header here must be at
    # server level (four spaces).
    add_headers = config.lines.grep(/add_header/).reject { |line| line.strip.start_with?("#") }
    assert add_headers.any?
    add_headers.each { |line| assert_match(/\A {4}add_header/, line, "nested add_header would drop HSTS: #{line}") }
  end

  # ---- ports, listeners and the http redirect ------------------------------

  test "live mode listens on 80 and 443 over both address families" do
    config = NginxConfig.render(build_app)

    # The missing [::] listen is exactly what broke mos-safeguards.com's HTTPS
    # for eight months.
    assert_includes config, "listen 80;"
    assert_includes config, "listen [::]:80;"
    assert_includes config, "listen 443 ssl;"
    assert_includes config, "listen [::]:443 ssl;"
    assert_includes config, "http2 on;"
  end

  test "staging mode renders the same block on 9080/9443 and redirects to its own port" do
    config = NginxConfig.render(build_app, staging: true)

    assert_includes config, "listen 9080;"
    assert_includes config, "listen [::]:9080;"
    assert_includes config, "listen 9443 ssl;"
    assert_includes config, "listen [::]:9443 ssl;"
    # Without the port the redirect bounces straight back to live Apache, which
    # is the one thing staging must not do.
    assert_includes config, "return 301 https://$host:9443$request_uri;"
    assert_not_includes config, "listen 443 ssl;"
    assert_structurally_valid config
  end

  test "staging writes to its own log files so the two can be compared" do
    live = NginxConfig.render(build_app(subdomain: "git"))
    stag = NginxConfig.render(build_app(subdomain: "git"), staging: true)

    assert_includes live, "access_log /var/log/ltvb/sites/git.ltvb.nl/access.log ltvb_scrubbed;"
    assert_includes stag, "access_log /var/log/ltvb/sites/git.ltvb.nl/staging-access.log ltvb_scrubbed;"
    assert_includes stag, "error_log  /var/log/ltvb/sites/git.ltvb.nl/staging-error.log warn;"
  end

  test "http redirects to https by default and serves nothing else" do
    http_block = NginxConfig.render(build_app).split(/^server \{$/)[1]

    app = build_app
    assert_includes http_block, "return 301 https://$host$request_uri;"

    # The acme webroot is the only `root` the redirect block may have. Assert
    # that precisely rather than "no root under /var/www/vhosts" — the ACME
    # webroot itself lives there (/var/www/vhosts/default/htdocs, where all 20
    # renewal configs already point), so the broad form fails on its own webroot.
    roots = http_block.scan(/^\s*root\s+(\S+?);/).flatten
    assert_equal [ NginxConfig::ACME_WEBROOT ], roots.uniq
    assert_not_includes http_block, app.public_path
    assert_no_match(/^\s*proxy_pass/, http_block)
  end

  test "the four hosts that legitimately serve on port 80 get the full site there" do
    config = NginxConfig.render(build_app(subdomain: "ai", domain: "lucasvanbriemen.nl", redirect_http: false))
    http_block = config.split(/^server \{$/)[1]

    assert_not_includes http_block, "return 301"
    assert_includes http_block, "root /var/www/vhosts/lucasvanbriemen.nl/ai.lucasvanbriemen.nl/public;"
    assert_includes http_block, "proxy_pass http://unix:/run/ltvb-app/ai.lucasvanbriemen.nl/puma.sock:;"
    assert_structurally_valid config
  end

  test "the default vhost claims default_server on every listener" do
    config = NginxConfig.render(build_app(subdomain: "lucasvanbriemen", domain: "lucasvanbriemen.nl",
                                          default_server: true))

    # Declared on IPv6 too: leaving it off means "whichever server block nginx
    # parsed first", which is not a decision to make by accident.
    assert_includes config, "listen 80 default_server;"
    assert_includes config, "listen [::]:80 default_server;"
    assert_includes config, "listen 443 default_server ssl;"
    assert_includes config, "listen [::]:443 default_server ssl;"
  end

  test "an ordinary vhost never claims default_server" do
    assert_not_includes NginxConfig.render(build_app), "default_server"
  end

  # ---- TLS -----------------------------------------------------------------

  test "tls reads the certbot lineage and leaves stapling off" do
    config = NginxConfig.render(build_app(subdomain: "git"))

    assert_includes config, "ssl_certificate     /etc/letsencrypt/live/git.ltvb.nl/fullchain.pem;"
    assert_includes config, "ssl_certificate_key /etc/letsencrypt/live/git.ltvb.nl/privkey.pem;"
    assert_includes config, "ssl_protocols TLSv1.2 TLSv1.3;"
    # Let's Encrypt retired OCSP; stapling would only add a resolver dependency.
    assert_no_match(/^\s*ssl_stapling/, config)
    # The session cache is one shared zone in http{}; per-server it would be a
    # duplicate zone name and nginx would refuse to start.
    assert_no_match(/^\s*ssl_session_cache/, config)
  end

  # ---- logging -------------------------------------------------------------

  test "the shared http config defines the scrubbing map and never logs the raw request" do
    shared = NginxConfig.shared_http_config

    assert_includes shared, "map $request_uri $ltvb_scrubbed_uri_once {"
    assert_includes shared, "map $ltvb_scrubbed_uri_once $ltvb_scrubbed_uri {"
    assert_includes shared, "log_format ltvb_scrubbed"
    assert_includes shared, "$ltvb_scrubbed_uri"
    # No bare $request anywhere outside the comments: it is the raw request
    # line, tokens and all. $request_uri/$request_method/$request_time are fine.
    directives = shared.lines.grep_v(/^\s*#/).join
    assert_no_match(/\$request[^_a-z]/, directives)
    assert_includes shared, "map $http_upgrade $ltvb_connection_upgrade {"
    assert_includes shared, "ssl_session_cache   shared:ltvb_tls:10m;"
  end

  test "the scrub pattern redacts auth_token wherever it appears in the query" do
    # Two passes, because that is what the two chained maps do.
    scrub = ->(uri) { apply_scrub(apply_scrub(uri)) }

    assert_equal "/x?auth_token=REDACTED", scrub.call("/x?auth_token=s3cr3t")
    assert_equal "/x?a=1&auth_token=REDACTED&b=2", scrub.call("/x?a=1&auth_token=s3cr3t&b=2")
    # A duplicated parameter is the case the second map exists for: the first
    # pass is greedy and only reaches the last one.
    assert_equal "/x?auth_token=REDACTED&auth_token=REDACTED",
                 scrub.call("/x?auth_token=one&auth_token=two")
  end

  test "the scrub pattern leaves unrelated parameters and lookalikes alone" do
    assert_equal "/x?token=keepme", apply_scrub("/x?token=keepme")
    # Only a real parameter boundary counts; a parameter merely ending in
    # auth_token is a different parameter.
    assert_equal "/x?xauth_token=keepme", apply_scrub("/x?xauth_token=keepme")
    assert_equal "/auth_token/path", apply_scrub("/auth_token/path")
  end

  test "the scrub is idempotent but still redacts a value that merely starts with the marker" do
    # The map runs twice over every request, so a second pass over an
    # already-clean URI must be a no-op.
    assert_equal "/x?auth_token=REDACTED", apply_scrub("/x?auth_token=REDACTED")
    assert_equal "/x?auth_token=REDACTED&b=2", apply_scrub("/x?auth_token=REDACTED&b=2")
    # ...but a real token that happens to begin with those letters is still a token.
    assert_equal "/x?auth_token=REDACTED", apply_scrub("/x?auth_token=REDACTEDbutnotreally")
  end

  test "every site logs through the scrubbing format" do
    config = NginxConfig.render(build_app)

    assert_equal 2, config.scan(/access_log \S+ ltvb_scrubbed;/).length
    assert_equal 2, config.scan(/error_log\s+\S+ warn;/).length
  end

  # ---- shape ---------------------------------------------------------------

  test "every kind renders a structurally plausible pair of server blocks" do
    App::SERVED_KINDS.each do |kind|
      config = NginxConfig.render(build_app(app_kind: kind, hsts: true, cable_path: "/cable",
                                            xaccel_path: "/var/www/vhosts/ltvb.nl/x/storage",
                                            ip_allowlist: "127.0.0.1"))
      assert_equal 2, config.scan(/^server \{$/).length, "#{kind}: expected two server blocks"
      assert_structurally_valid config
    end
  end

  private

  # `cable_path`, `cable_port`, `xaccel_path`, `redirect_http` and
  # `default_server` are typed vhost fields that are not yet columns on `apps`;
  # they are attached as singleton readers so the renderer sees exactly the
  # interface it will see once the migration lands.
  def build_app(**overrides)
    columns = App.column_names.map(&:to_sym)
    defaults = { name: "test app", app_kind: "rails", subdomain: "git", domain: "ltvb.nl",
                 git_repo_url: "git@github.com:ltvb/test.git", doc_root_suffix: "public" }

    # No validations are run: the point is to hand the renderer records the
    # model would have rejected, because a row can be written by a console, an
    # import, or an update_column that skipped them.
    app = App.new(defaults.merge(overrides.slice(*columns)))
    overrides.except(*columns).each { |name, value| app.define_singleton_method(name) { value } }
    app
  end

  # One pass of the nginx map, in Ruby: the same pattern and the same
  # replacement the template writes, with nginx's ${1} capture syntax
  # translated to Ruby's. Both are PCRE-compatible, so this is a real check of
  # the shipped strings rather than a restatement of them.
  # Runs nginx's map through Ruby's regex engine so the pattern is exercised
  # rather than merely asserted about. Only the capture-reference syntax differs:
  # nginx writes ${name}, Ruby writes \k<name>. (nginx rejects the positional
  # ${1} form outright — "unknown \"1\" variable" — which is why these are named.)
  def apply_scrub(uri)
    replacement = NginxConfig::AUTH_TOKEN_REPLACEMENT.gsub(/\$\{(\w+)\}/) { "\\k<#{Regexp.last_match(1)}>" }
    uri.sub(Regexp.new(NginxConfig::AUTH_TOKEN_PATTERN), replacement)
  end

  # nginx is not installed in CI, so this is the cheap structural half of
  # `nginx -t`: balanced blocks, and every directive actually terminated.
  def assert_structurally_valid(config)
    depth = 0

    config.each_line.with_index(1) do |line, number|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?("#")

      assert_no_match(/[\x00-\x08\x0b\x0c\x0e-\x1f]/, stripped, "line #{number} has a control character")
      assert stripped.end_with?(";", "{", "}"),
             "line #{number} is not a terminated directive: #{stripped.inspect}"

      depth += stripped.count("{") - stripped.count("}")
      assert depth >= 0, "line #{number} closes a block that was never opened"
    end

    assert_equal 0, depth, "unbalanced braces in rendered config"
  end
end
