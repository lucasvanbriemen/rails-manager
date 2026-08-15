require "test_helper"
require "tmpdir"
require "rake"

# ManagerImport lives in lib/tasks/import.rake and has no test file of its own.
# It is loaded here because the defect worth testing spans both files: the
# inventory decides a probe failed, and the import is what must then refuse to
# write. Testing either half alone proves nothing about the app that got
# rewritten to "static".
load Rails.root.join("lib/tasks/import.rake").to_s unless defined?(ManagerImport)

# Fixtures under test/fixtures/files/plesk-export are verbatim captures from
# server.ltvb.nl, so every parser is tested against the shape it will actually
# meet -- including the ones Plesk got wrong. The one edit: login.ltvb.nl's real
# RAILS_MASTER_KEY is replaced with "deadbeef..." so a live production secret is
# not committed here. The parser cannot tell the difference.
class ServerInventoryTest < ActiveSupport::TestCase
  EXPORT_DIR = Rails.root.join("test/fixtures/files/plesk-export").freeze

  def inventory(claimed_paths: [])
    ServerInventory.new(
      export_dir: EXPORT_DIR.to_s,
      disk: ServerInventory::MarkerDisk.new(File.read(EXPORT_DIR.join("disk-layout.tsv"))),
      claimed_paths: claimed_paths
    )
  end

  def entry(name) = inventory.entries.find { |e| e.name == name }

  # The same export, probed by a disk that can see nothing -- which is exactly
  # what `ltvb` gets, because the five other webspaces are 0750 owner:psaserv.
  def blind_inventory
    ServerInventory.new(export_dir: EXPORT_DIR.to_s, disk: ServerInventory::MarkerDisk.new(""))
  end

  # admin.rijschool-mos.nl is the clearest victim of a degraded probe: it is a
  # PHP app served straight out of its checkout, so neither of derive_kind's two
  # fallbacks (Passenger, a public/ docroot) rescues it and a blind run
  # classifies it "static" -- an nginx config with no PHP in it at all.
  def php_app(**overrides)
    App.create!({ name: "Rijschool admin", subdomain: "admin", domain: "rijschool-mos.nl",
                  app_kind: "php", php_version: "8.3", primary_db_kind: "external",
                  doc_root_suffix: "", runtime_user: "rijschool-mos.nl_gze6m7rrghq",
                  git_repo_url: "git@github.com:lucasvanbriemen/rijschool.git" }.merge(overrides))
  end

  def blind_entry(name) = blind_inventory.entries.find { |e| e.name == name }

  # ---- TSV -------------------------------------------------------------------

  test "tsv parsing keeps trailing empty columns" do
    # Plesk spells "no post-deploy script" as a trailing empty field; dropping
    # it shifts every later column by one.
    rows = ServerInventory.parse_tsv("a\tb\tc\n1\t2\t\n")
    assert_equal({ "a" => "1", "b" => "2", "c" => "" }, rows.first)
  end

  test "tsv parsing of an unreadable file yields no rows rather than raising" do
    assert_equal [], ServerInventory.parse_tsv("")
  end

  test "missing export files are collected as warnings, not exceptions" do
    inv = ServerInventory.new(export_dir: "/nonexistent", disk: ServerInventory::MarkerDisk.new(""))
    assert_equal [], inv.entries
    assert inv.warnings.any? { |w| w.include?("vhost-summary.tsv") }
  end

  # ---- the master key --------------------------------------------------------

  test "RAILS_MASTER_KEY is rescued from the login.ltvb.nl vhost SetEnv" do
    # This is the whole point of the import: the app has no config/master.key,
    # so Apache's vhost.conf holds the only copy of the key.
    login = entry("login.ltvb.nl")
    assert_equal "deadbeefdeadbeefdeadbeefdeadbeef", login.attributes[:master_key]
    assert_equal "RAILS_MASTER_KEY=deadbeefdeadbeefdeadbeefdeadbeef", login.attributes[:env_text]
    assert login.flags.any? { |f| f.include?("RAILS_MASTER_KEY rescued") }
  end

  test "SetEnv is attributed to the host whose banner it appears under" do
    envs = ServerInventory.parse_set_envs(<<~CONF)
      HOST: git.ltvb.nl
      Protocols http/1.1
      HOST: login.ltvb.nl
      SetEnv RAILS_MASTER_KEY abc123
      SetEnv OTHER value
    CONF
    assert_nil envs["git.ltvb.nl"]
    assert_equal({ "RAILS_MASTER_KEY" => "abc123", "OTHER" => "value" }, envs["login.ltvb.nl"])
  end

  test "hosts without a SetEnv get no master key" do
    assert_nil entry("music.ltvb.nl").attributes[:master_key]
    assert_nil entry("music.ltvb.nl").attributes[:env_text]
  end

  # ---- kind derivation -------------------------------------------------------

  test "kind comes from the checkout, most specific marker first" do
    assert_equal "rails",   ServerInventory.derive_kind(%w[Gemfile .git])
    assert_equal "laravel", ServerInventory.derive_kind(%w[artisan composer.json index.html])
    assert_equal "php",     ServerInventory.derive_kind(%w[composer.json index.html])
    assert_equal "static",  ServerInventory.derive_kind(%w[index.html])
  end

  test "a Laravel checkout with no vhost is a cron app, not a laravel app" do
    assert_equal "cron", ServerInventory.derive_kind(%w[artisan composer.json], cron: true)
  end

  test "a bare php file is enough to make it a php app" do
    # ai.lucasvanbriemen.nl is one commits.php and nothing else.
    assert_equal "php", ServerInventory.derive_kind(%w[php-files])
    assert_equal "php", entry("ai.lucasvanbriemen.nl").app_kind
  end

  test "an unreadable checkout falls back to how Apache serves it" do
    # The manager runs as `ltvb` and cannot stat the other five webspaces.
    assert_equal "rails",   ServerInventory.derive_kind([], passenger: true)
    assert_equal "laravel", ServerInventory.derive_kind([], public_docroot: true)
    assert_equal "static",  ServerInventory.derive_kind([])
  end

  test "every live hostname is classified from its real checkout" do
    kinds = inventory.entries.reject(&:archived?).to_h { |e| [ e.name, e.app_kind ] }

    assert_equal %w[aio.ltvb.nl apps.ltvb.nl git.ltvb.nl login.ltvb.nl mail.ltvb.nl music.ltvb.nl],
                 kinds.select { |_, kind| kind == "rails" }.keys.sort
    assert_equal %w[components.lucasvanbriemen.nl github.lucasvanbriemen.nl mos-safeguards.com
                    senne.ltvb.nl voordezorgmanagement.nl],
                 kinds.select { |_, kind| kind == "laravel" }.keys.sort
    assert_equal %w[ai.ltvb.nl calendar.lucasvanbriemen.nl email.lucasvanbriemen.nl],
                 kinds.select { |_, kind| kind == "cron" }.keys.sort
  end

  # ---- host and path derivation ---------------------------------------------

  test "the webspace directory decides what is apex and what is a subdomain" do
    # Both live under /var/www/vhosts/mos-safeguards.com, and only the directory
    # name distinguishes the apex site from a subdomain of it.
    assert_equal [ nil, "mos-safeguards.com" ],
                 ServerInventory.split_host("mos-safeguards.com", "mos-safeguards.com")
    assert_equal [ "admin", "mos-safeguards.com" ],
                 ServerInventory.split_host("admin.mos-safeguards.com", "mos-safeguards.com")
  end

  test "a host served from outside the webspaces splits off its first label" do
    # Roundcube serves from /usr/share/psa-roundcube; there is no webspace.
    assert_equal [ "webmail", "ltvb.nl" ], ServerInventory.split_host("webmail.ltvb.nl", nil)
  end

  test "apex hosts are flagged, because App cannot express a blank subdomain" do
    apex = inventory.entries.select(&:apex?).map(&:name).sort
    assert_equal %w[djtim.eu ltvb.nl lucasvanbriemen.nl mos-safeguards.com
                    rijschool-mos.nl voordezorgmanagement.nl], apex
  end

  test "a public docroot becomes a suffix, a bare docroot does not" do
    assert_equal "public", entry("git.ltvb.nl").attributes[:doc_root_suffix]
    assert_equal "", entry("admin.rijschool-mos.nl").attributes[:doc_root_suffix]
    assert_equal "/var/www/vhosts/ltvb.nl/git.ltvb.nl",
                 ServerInventory.checkout_dir("/var/www/vhosts/ltvb.nl/git.ltvb.nl/public")
  end

  test "a docroot outside the webspaces is flagged as unmodelled" do
    assert entry("webmail.ltvb.nl").flags.any? { |f| f.include?("outside /var/www/vhosts") }
  end

  # ---- git -------------------------------------------------------------------

  test "the checkout's branch beats Plesk's stale record and the divergence is reported" do
    # Plesk still believes git.ltvb.nl is on the abandoned rails-rewrite branch.
    git = entry("git.ltvb.nl")
    assert_equal "rails-rewrite", git.plesk_branch
    assert_equal "main", git.disk_branch
    assert_equal "main", git.attributes[:git_branch]
    assert git.flags.any? { |f| f.include?("branch divergence") }
  end

  test "mail and music are corrected from master to main" do
    %w[mail.ltvb.nl music.ltvb.nl].each do |name|
      assert_equal "master", entry(name).plesk_branch
      assert_equal "main", entry(name).attributes[:git_branch], "#{name} should follow the checkout"
    end
  end

  test "a branch Plesk records and disk agrees with raises no divergence" do
    aio = entry("aio.ltvb.nl")
    assert_equal "master", aio.attributes[:git_branch]
    assert_empty aio.flags.grep(/branch divergence/)
  end

  test "the on-disk remote wins over Plesk's fetch_url" do
    # Plesk records https://github.com/lucasvanbriemen/github for git.ltvb.nl;
    # the working copy actually pulls over ssh.
    assert_equal "git@github.com:lucasvanbriemen/github.git", entry("git.ltvb.nl").attributes[:git_repo_url]
  end

  test "the four apps whose remote is gone are reported with their bundle" do
    stranded = inventory.entries
                        .select { |e| e.remote_status.present? && e.remote_status != "REACHABLE" }
                        .map(&:name).sort
    assert_equal %w[login.rijschool-mos.nl senne.ltvb.nl student.rijschool-mos.nl
                    voordezorgmanagement.nl], stranded

    stranded.each do |name|
      assert entry(name).flags.any? { |f| f.start_with?("recovery bundle:") },
             "#{name} must point at the bundle that is now its only backup"
    end
  end

  test "a push-mode repo takes the bare repo on this server as its origin" do
    senne = entry("senne.ltvb.nl")
    assert_equal "/var/www/vhosts/ltvb.nl/git/laravel_060854", senne.attributes[:git_repo_url]
    assert senne.flags.any? { |f| f.include?("push-mode") }
  end

  test "an app under no git at all points at its own directory and says so" do
    djtim = entry("djtim.eu")
    assert_equal "/var/www/vhosts/djtim.eu/httpdocs", djtim.attributes[:git_repo_url]
    assert djtim.flags.any? { |f| f.include?("not under git") }
  end

  # ---- post-deploy scripts ---------------------------------------------------

  test "a Plesk script that operates on another app's directory is not imported" do
    # mail.ltvb.nl and git.ltvb.nl both carry a verbatim copy of login's script,
    # which cds into /var/www/vhosts/ltvb.nl/login.ltvb.nl. Running it as
    # mail's post-deploy would rebuild login instead.
    script = 'APP=/var/www/vhosts/ltvb.nl/login.ltvb.nl\ncd "$APP"\nbundle install'
    assert_empty ServerInventory.safe_post_deploy_commands(script, "/var/www/vhosts/ltvb.nl/mail.ltvb.nl")
    assert_equal 3, ServerInventory.safe_post_deploy_commands(script, "/var/www/vhosts/ltvb.nl/login.ltvb.nl").size
  end

  test "a shell program is not imported as a list of commands" do
    # App#post_deploy_command_list runs each line in its own shell, so `set -e`
    # and a `cd` on separate lines are not the program the author wrote.
    script = '#!/bin/bash\nset -euo pipefail\ncd /var/www/vhosts/ltvb.nl/login.ltvb.nl\nbundle install'
    assert_empty ServerInventory.safe_post_deploy_commands(script, "/var/www/vhosts/ltvb.nl/login.ltvb.nl")
  end

  test "a genuine command list is imported, with Plesk's escaped newlines undone" do
    commands = ServerInventory.safe_post_deploy_commands(
      'php artisan migrate --force\nnpm run build', "/var/www/vhosts/lucasvanbriemen.nl/github.lucasvanbriemen.nl"
    )
    assert_equal [ "php artisan migrate --force", "npm run build" ], commands
    assert_equal "php artisan migrate --force\nnpm run build\nphp artisan optimize:clear",
                 entry("github.lucasvanbriemen.nl").attributes[:post_deploy_commands]
  end

  test "rails apps keep the rejected script in notes and flags rather than losing it" do
    mail = entry("mail.ltvb.nl")
    assert_nil mail.attributes[:post_deploy_commands]
    assert_includes mail.attributes[:notes], "rails assets:precompile"
    assert mail.flags.any? { |f| f.include?("post-deploy script not imported") }
  end

  # ---- serving behaviours ----------------------------------------------------

  test "the login allowlist survives as addresses App will accept" do
    allowlist = entry("login.ltvb.nl").attributes[:ip_allowlist]
    assert_equal "62.194.231.108 2001:1c00:9501:6700::/64 93.184.105.110 87.106.231.214 127.0.0.1 ::1",
                 allowlist
    assert App.new(ip_allowlist: allowlist).tap(&:validate).errors[:ip_allowlist].empty?
  end

  test "an absent allowlist is nil rather than the literal string none" do
    assert_nil ServerInventory.parse_allowlist("none")
    assert_nil ServerInventory.parse_allowlist("")
    assert_nil entry("music.ltvb.nl").attributes[:ip_allowlist]
  end

  test "HSTS is read from the header, not assumed from TLS" do
    # Every host has TLS; exactly one sends Strict-Transport-Security.
    assert entry("lucasvanbriemen.nl").attributes[:hsts]
    assert_not entry("ltvb.nl").attributes[:hsts]
  end

  # ---- users, versions -------------------------------------------------------

  test "the suexec user is carried through, per webspace" do
    assert_equal "ltvb", entry("music.ltvb.nl").attributes[:runtime_user]
    assert_equal "lucasvanbriemen.nl_p8c08835y9j", entry("github.lucasvanbriemen.nl").attributes[:runtime_user]
    assert_equal "voordezorgmanagement._rhc4zy0iyc", entry("voordezorgmanagement.nl").attributes[:runtime_user]
  end

  test "cron apps inherit the owner of the webspace they sit in" do
    assert_equal "ltvb", entry("ai.ltvb.nl").attributes[:runtime_user]
    assert_equal "lucasvanbriemen.nl_p8c08835y9j", entry("calendar.lucasvanbriemen.nl").attributes[:runtime_user]
  end

  test "the php version comes from the host's own FPM pool, never the distro pool" do
    assert_equal "8.3", entry("djtim.eu").attributes[:php_version]
    assert_nil inventory.entries.find { |e| e.name == "www" }
  end

  test "ruby version is read from the checkout and stripped of its ruby- prefix" do
    assert_equal "3.3.8", ServerInventory.normalize_ruby_version("ruby=ruby-3.3.8")
    assert_equal "3.3.8", entry("git.ltvb.nl").attributes[:ruby_version]
  end

  # ---- cron ------------------------------------------------------------------

  test "both crontab spellings of a Laravel scheduler are recognised" do
    dirs = ServerInventory.parse_cron_apps(<<~CRON)
      * * * * * cd /var/www/vhosts/ltvb.nl/ai.ltvb.nl && php artisan schedule:run >> /dev/null 2>&1
      * * * * * /usr/bin/php '/var/www/vhosts/lucasvanbriemen.nl/todo.lucasvanbriemen.nl/artisan' 'schedule:run'
      #* * * * * /usr/bin/php '/var/www/vhosts/x/artisan' 'schedule:run'
      0 0 * * * python3 /var/www/vhosts/rijschool-mos.nl/admin.rijschool-mos.nl/cron/get_users/main.py
    CRON
    assert_equal [ "/var/www/vhosts/ltvb.nl/ai.ltvb.nl",
                   "/var/www/vhosts/lucasvanbriemen.nl/todo.lucasvanbriemen.nl" ], dirs
  end

  test "a scheduled app that also has a vhost is not imported twice" do
    # github.lucasvanbriemen.nl runs schedule:run AND serves HTTP.
    matches = inventory.entries.select { |e| e.name == "github.lucasvanbriemen.nl" }
    assert_equal 1, matches.size
    assert_equal "laravel", matches.first.app_kind
    assert matches.first.attributes[:serves_http]
  end

  test "cron apps resolve to the right checkout without a vhost" do
    ai = entry("ai.ltvb.nl")
    assert_not ai.attributes[:serves_http]
    assert_equal [ "ai", "ltvb.nl" ], [ ai.attributes[:subdomain], ai.attributes[:domain] ]
    assert_equal "/var/www/vhosts/ltvb.nl/ai.ltvb.nl", App.new(ai.attributes).app_path
  end

  # ---- orphans ---------------------------------------------------------------

  test "abandoned directories are recorded as archived repos, not skipped" do
    orphans = inventory.entries.select(&:archived?)
    assert_equal 13, orphans.size
    assert_includes orphans.map(&:name), "ltvb.nl/site1"
    assert_includes orphans.map(&:name), "mos-safeguards.com.unremoved_data/httpdocs"
    orphans.each do |orphan|
      assert_equal "repo", orphan.app_kind
      assert orphan.attributes[:deploy_path].present?, "#{orphan.name} must record where it is"
      assert_not orphan.attributes[:serves_http]
    end
  end

  test "Plesk's own scaffolding in a webspace is never mistaken for an app" do
    names = inventory.entries.map(&:name)
    %w[error_docs logs git bin lib64 tmp].each do |scaffolding|
      assert_not_includes names, "ltvb.nl/#{scaffolding}"
    end
  end

  test "a checkout an App already owns is not re-imported as abandoned" do
    # ui-components is a live, tracked repo with no vhost -- on disk it is
    # indistinguishable from an abandoned directory.
    claimed = inventory(claimed_paths: [ "/var/www/vhosts/ltvb.nl/ui-components" ])
    assert_not_includes claimed.entries.map(&:name), "ltvb.nl/ui-components"
    assert_includes claimed.entries.map(&:name), "ltvb.nl/ui-components.laravel-wrong.bak"
  end

  # ---- the whole sweep -------------------------------------------------------

  test "every hostname Apache serves produces exactly one entry" do
    served = inventory.entries.select { |e| e.attributes[:serves_http] }.map(&:name).sort
    assert_equal 22, served.size
    assert_equal served, served.uniq
    assert_includes served, "webmail.ltvb.nl"
    assert_includes served, "senne.ltvb.nl"
  end

  test "auto_deploy is off on everything imported" do
    # 25 apps redeploying on push is not a migration plan.
    assert inventory.entries.none? { |e| e.attributes[:auto_deploy] }
  end

  test "every entry builds an App the model accepts, apex hosts aside" do
    invalid = inventory.entries.reject do |e|
      app = App.new(e.attributes)
      app.valid? || (e.apex? && (app.errors.attribute_names - %i[subdomain]).empty?)
    end
    assert_empty invalid.map { |e| [ e.name, App.new(e.attributes).tap(&:validate).errors.full_messages ] }
  end

  test "entry match keys are unique and match how an App is looked up" do
    keys = inventory.entries.map(&:match_key)
    assert_equal keys, keys.uniq

    app = App.new(subdomain: "git", domain: "ltvb.nl")
    assert_equal "git.ltvb.nl", ServerInventory.match_key_for(app)
    assert_equal "/var/www/vhosts/ltvb.nl/ui-components",
                 ServerInventory.match_key_for(App.new(deploy_path: "/var/www/vhosts/ltvb.nl/ui-components"))
  end

  test "attributes carry no clock so a re-import can detect an unchanged server" do
    assert_equal inventory.entries.map(&:attributes), inventory.entries.map(&:attributes)
  end

  # ---- the disk probe --------------------------------------------------------

  test "a captured probe answers directory listings as well as markers" do
    disk = ServerInventory::MarkerDisk.new("/var/www/vhosts/ltvb.nl/site1\tindex.html\n")
    assert_equal %w[index.html], disk.markers("/var/www/vhosts/ltvb.nl/site1")
    assert_equal %w[site1], disk.children("/var/www/vhosts/ltvb.nl")
    assert_equal %w[ltvb.nl], disk.children("/var/www/vhosts")
    assert_equal [], disk.markers("/var/www/vhosts/ltvb.nl/nothing-here")
  end

  # ---- the degraded probe ----------------------------------------------------
  # The webspaces are 0750 owner:psaserv and the manager runs as `ltvb`, so
  # "the probe returned nothing" is the *expected* outcome of a mistake, not an
  # exotic one. derive_kind's floor is "static", which is why an unchecked
  # degraded probe rewrote every rails and laravel app into a static site.

  test "a checkout that may not be entered is UNREADABLE, not empty" do
    skip "running as root, where nothing is unreadable" if Process.uid.zero?

    Dir.mktmpdir do |root|
      checkout = File.join(root, "app")
      Dir.mkdir(checkout)
      File.write(File.join(checkout, "Gemfile"), "")
      File.chmod(0o000, checkout)

      begin
        markers = ServerInventory::LiveDisk.new.markers(checkout)
        assert_equal [ ServerInventory::UNREADABLE ], markers
        assert ServerInventory.probe_failed?(markers)
      ensure
        File.chmod(0o755, checkout)
      end
    end
  end

  test "a checkout that genuinely is not there is empty, not UNREADABLE" do
    Dir.mktmpdir do |root|
      assert_equal [], ServerInventory::LiveDisk.new.markers(File.join(root, "gone"))
    end
  end

  test "no markers at all is a failed measurement, not a static site" do
    assert ServerInventory.probe_failed?([])
    assert ServerInventory.probe_failed?([ ServerInventory::UNREADABLE ])
    assert_not ServerInventory.probe_failed?(%w[index.html])
  end

  test "a probe that read nothing flags every served and cron entry" do
    degraded = blind_inventory.entries.select(&:probe_failed?).map(&:name)

    assert_includes degraded, "git.ltvb.nl"
    assert_includes degraded, "ai.ltvb.nl"
    assert_equal blind_inventory.entries.size, degraded.size
  end

  test "the degraded flag says which app it is about and what it would have written" do
    flag = blind_entry("admin.rijschool-mos.nl").flags.find { |f| f.start_with?("checkout not readable") }

    assert_includes flag, "/var/www/vhosts/rijschool-mos.nl/admin.rijschool-mos.nl"
    assert_includes flag, "app_kind=static"
  end

  test "a readable probe flags nothing" do
    assert_empty inventory.entries.select(&:probe_failed?)
  end

  test "an empty abandoned directory is not a degraded probe" do
    # mos-safeguards.com.unremoved_data/httpdocs really is empty. Its kind is
    # "repo" whatever the probe saw, so there is nothing to get wrong.
    orphan = entry("mos-safeguards.com.unremoved_data/httpdocs")
    assert_equal "repo", orphan.app_kind
    assert_not orphan.probe_failed?
  end

  # ---- what the import does with a degraded probe -----------------------------

  test "a degraded probe does not rewrite an existing app's kind" do
    app   = php_app
    entry = blind_entry("admin.rijschool-mos.nl")

    assert entry.probe_failed?
    assert_equal "static", entry.app_kind, "the fixture must reproduce the bad classification"

    changes = ManagerImport.refreshable_changes(entry, app)

    ManagerImport::PROBE_DERIVED.each do |field|
      assert_not changes.key?(field), "#{field} must not be refreshed from a probe that read nothing"
    end
    assert_equal "php", app.app_kind
    # primary_db_kind is derived from app_kind, so refreshing it would launder
    # the same guess back in through the other door.
    assert_equal "external", app.primary_db_kind
  end

  test "a degraded probe still refreshes what Apache and Plesk told us" do
    # The vhost, the suexec user and git are readable whatever the webspace
    # permissions are, so suppressing those too would trade one silently wrong
    # answer for another.
    app     = php_app(runtime_user: "wrong", git_branch: "stale")
    changes = ManagerImport.refreshable_changes(blind_entry("admin.rijschool-mos.nl"), app)

    assert_equal "rijschool-mos.nl_gze6m7rrghq", changes[:runtime_user]
    assert_equal "main", changes[:git_branch]
  end

  test "a degraded probe still creates a row it has never seen before" do
    # Nothing to protect on a new record, and an untracked live site is worse
    # than one recorded with a weak kind -- the report flags it either way.
    changes = ManagerImport.refreshable_changes(blind_entry("admin.rijschool-mos.nl"), App.new)

    assert_equal "static", changes[:app_kind]
  end

  test "an import whose probe read nothing is refused, and writes nothing" do
    app = php_app

    output, = capture_io do
      assert_raises(ManagerImport::DegradedProbe) do
        # LiveDisk on a laptop: /var/www/vhosts does not exist, so every probe
        # comes back empty -- the same shape as running as the wrong user.
        ManagerImport.run(export_dir: EXPORT_DIR.to_s, dry_run: false)
      end
    end

    assert_equal 1, App.count, "a refused run must not create anything"
    assert_equal "php", app.reload.app_kind
    assert_includes output, "REFUSED"
    assert_includes output, "DEGRADED PROBE"
  end

  test "a degraded import can be forced, and still protects the probed fields" do
    app = php_app(runtime_user: "wrong")

    capture_io { ManagerImport.run(export_dir: EXPORT_DIR.to_s, dry_run: false, allow_degraded: true) }

    assert_equal "php", app.reload.app_kind, "forcing the run must not relax the field guard"
    assert_equal "rijschool-mos.nl_gze6m7rrghq", app.runtime_user
  end

  # ---- cron ------------------------------------------------------------------

  test "every crontab line in the export becomes an argv array" do
    jobs = inventory.scheduled_jobs

    assert_equal 8, jobs.size
    assert_empty inventory.unmodellable_jobs
    assert jobs.all? { |job| job[:argv].any? }, "a job with no argv is a job nothing can run"
  end

  test "the shell parts of a cron line become fields, not arguments" do
    # `cd <dir> && php artisan schedule:run >> /dev/null 2>&1` -- the one line
    # here that needs a shell for both halves. A ScheduledJob is run without
    # one, so both halves have to be represented instead of embedded.
    ai = inventory.scheduled_jobs.find { |job| job[:name] == "ai-ltvb-nl-schedule-run" }

    assert_equal [ "php", "artisan", "schedule:run" ], ai[:argv]
    assert_equal "/var/www/vhosts/ltvb.nl/ai.ltvb.nl", ai[:working_directory]
    assert ai[:discard_output]
  end

  test "quoted arguments stay one argv element each" do
    calendar = inventory.scheduled_jobs.find { |job| job[:name].start_with?("calendar") }

    assert_equal [ "/usr/bin/php",
                   "/var/www/vhosts/lucasvanbriemen.nl/calendar.lucasvanbriemen.nl/artisan",
                   "schedule:run" ], calendar[:argv]
    assert_nil calendar[:working_directory]
  end

  test "MAILTO is captured, because it is why a failing job is silent" do
    quiet = inventory.scheduled_jobs.find { |job| job[:user].start_with?("lucasvanbriemen") }

    assert_equal({ "MAILTO" => "", "SHELL" => "/bin/bash" }, quiet[:environment])
  end

  test "a SHELL changed halfway down a crontab does not leak backwards" do
    # rijschool's crontab sets SHELL=/bin/sh, runs fetch_url, then switches to
    # /bin/bash for the python jobs.
    jobs = inventory.scheduled_jobs.select { |job| job[:user].start_with?("rijschool") }

    assert_equal "/bin/sh", jobs.first[:environment]["SHELL"]
    assert_equal "/bin/bash", jobs.last[:environment]["SHELL"]
  end

  test "the tab-separated form every crontab on this host uses is parsed" do
    jobs = ServerInventory.parse_crontabs("# user: ltvb\n0\t*\t*\t*\t*\t/bin/true\n")

    assert_equal "0 * * * *", jobs.first[:cron_schedule]
    assert_equal [ "/bin/true" ], jobs.first[:argv]
  end

  test "macros are a schedule, comments and blank lines are not jobs" do
    jobs = ServerInventory.parse_crontabs(<<~CRON)
      # user: ltvb
      #* * * * * /bin/disabled

      @daily /usr/bin/backup
    CRON

    assert_equal 1, jobs.size
    assert_equal "@daily", jobs.first[:cron_schedule]
  end

  test "a cron line with a pipeline is reported rather than half-parsed" do
    # Shellwords returns "|" as an ordinary word. argv cannot express a
    # pipeline, so half-parsing it would store something that runs differently
    # from what cron runs -- worse than admitting it is not modellable.
    jobs = ServerInventory.parse_crontabs("# user: ltvb\n0 * * * * /bin/foo | /bin/bar\n")

    assert_equal 1, jobs.size
    assert_empty jobs.first[:argv]
    assert_equal "0 * * * * /bin/foo | /bin/bar", jobs.first[:raw]
  end

  test "derived job names are stable, unique and usable as unit names" do
    names = inventory.scheduled_jobs.map { |job| job[:name] }

    assert_equal names, names.uniq
    assert_equal names, blind_inventory.scheduled_jobs.map { |job| job[:name] }
    assert names.all? { |name| name.match?(SystemdUnit::UNIT_NAME) }, names.inspect
    # The three rijschool python jobs differ only in which script they run.
    assert_includes names, "admin-rijschool-mos-nl-get-users-main"
    assert_includes names, "admin-rijschool-mos-nl-makelessen-main"
  end

  test "two identical lines under one user still get distinct names" do
    jobs = ServerInventory.parse_crontabs(<<~CRON)
      # user: ltvb
      0 1 * * * /usr/bin/backup
      0 2 * * * /usr/bin/backup
    CRON

    assert_equal %w[ltvb-bin-backup ltvb-bin-backup-2], jobs.map { |job| job[:name] }
  end

  test "the missing crontabs.txt is a warning that says what was lost" do
    # The real export does not contain it -- checked on the server -- so this is
    # the state a live import runs in until the capture script grows one.
    inv = ServerInventory.new(export_dir: "/nonexistent", disk: ServerInventory::MarkerDisk.new(""))

    assert_empty inv.scheduled_jobs
    assert inv.warnings.any? { |warning| warning.include?("crontabs.txt is not in the export") }
    assert inv.warnings.any? { |warning| warning.include?("cron-only app") }
  end

  test "a crontab line an adopted row already describes is not reported as new" do
    # The migration adopts these nine by hand and the parser derives them from
    # the export; the report is only useful if the two recognise each other.
    ScheduledJob.create!(inventory.scheduled_jobs.find { |job| job[:name].start_with?("ai-") }.except(:raw))

    names = ManagerImport.unadopted_jobs(inventory).map { |job| job[:name] }
    assert_not_includes names, "ai-ltvb-nl-schedule-run"
    assert_includes names, "calendar-lucasvanbriemen-nl-schedule-run"
  end

  test "renaming an adopted row by hand does not make its crontab line look new" do
    # Matching is by (user, schedule, argv). A name is ours to choose, and
    # choosing a different one must not adopt the same line twice.
    parsed = inventory.scheduled_jobs.find { |job| job[:name].start_with?("ai-") }
    ScheduledJob.create!(parsed.except(:raw).merge(name: "renamed-by-hand"))

    assert_empty ManagerImport.unadopted_jobs(inventory).select { |job| job[:name].start_with?("ai-") }
  end

  test "a crontab handed in directly beats the export" do
    inv = ServerInventory.new(export_dir: EXPORT_DIR.to_s,
                              disk: ServerInventory::MarkerDisk.new(""),
                              crontabs: "# user: root\n* * * * * /usr/local/bin/rails-deploy-watch.sh\n")

    assert_equal [ "root-bin-rails-deploy-watch" ], inv.scheduled_jobs.map { |job| job[:name] }
  end

  # ---- acme ------------------------------------------------------------------

  test "the acme webroot is the one certbot actually renews through" do
    # Read off the server: 20 of the 21 renewal configs are `authenticator =
    # webroot` with this webroot_path, and each has a [[webroot_map]] pointing
    # its one domain at the same directory.
    assert_equal "/var/www/vhosts/default/htdocs", ServerInventory::ACME_WEBROOT
    assert_equal ServerInventory::ACME_WEBROOT, inventory.acme_webroot
  end

  test "a captured renewal config is believed over the recorded default" do
    webroot = ServerInventory.parse_acme_webroot(<<~CONF)
      authenticator = webroot
      webroot_path = /srv/acme,
      [[webroot_map]]
      ltvb.nl = /srv/acme
    CONF

    assert_equal "/srv/acme", webroot
  end

  test "renewal configs that disagree have no single webroot" do
    # One shared nginx location can only serve one directory; if the configs
    # point at two, saying "the" webroot would be a guess.
    assert_nil ServerInventory.parse_acme_webroot("webroot_path = /a,\nwebroot_path = /b,\n")
  end

  test "an apache authenticator contributes no webroot at all" do
    # server.ltvb.nl (the panel's own cert) renews through Apache, so it has no
    # webroot to read and stops renewing when Apache goes.
    assert_nil ServerInventory.parse_acme_webroot("authenticator = apache\ninstaller = apache\n")
  end
end
