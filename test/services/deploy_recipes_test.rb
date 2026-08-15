require "test_helper"
require "tmpdir"

class DeployRecipesTest < ActiveSupport::TestCase
  def app(**overrides)
    App.new({
      name: "Git", app_kind: "rails", subdomain: "git", domain: "ltvb.nl",
      ruby_version: "3.3.8", git_repo_url: "git@github.com:x/y.git",
      primary_db_kind: "sqlite"
    }.merge(overrides))
  end

  def laravel_app(**overrides)
    app(**{ app_kind: "laravel", subdomain: "music", ruby_version: nil,
            php_version: "8.3", primary_db_kind: "external" }.merge(overrides))
  end

  def keys_for(a, **opts)
    DeployRecipes.for(a, release_path: "/tmp/release", **opts).map(&:key)
  end

  # Every kind, both database kinds, migrations allowed and not: the whole space
  # of steps this module can emit.
  def every_step
    apps = [
      app, app(primary_db_kind: "external"), laravel_app,
      app(app_kind: "cron", subdomain: nil, domain: nil, ruby_version: nil, php_version: "8.3", serves_http: false),
      app(app_kind: "php", ruby_version: nil, php_version: "8.3", doc_root_suffix: ""),
      app(app_kind: "static", ruby_version: nil, doc_root_suffix: ""),
      app(app_kind: "repo", deploy_path: "/srv/ui-components", ruby_version: nil,
          post_deploy_commands: "npm ci\n./propagate.sh\n")
    ]

    apps.flat_map do |a|
      [ true, false ].flat_map { |allow| DeployRecipes.for(a, release_path: "/tmp/r", allow_migrations: allow) }
    end
  end

  # --- rails ----------------------------------------------------------------

  test "the rails recipe builds, migrates, precompiles, then restarts" do
    assert_equal %i[bundle migrate assets restart], keys_for(app)
  end

  test "migrations are skipped when the app is not allowed to run them" do
    assert_equal %i[bundle assets restart], keys_for(app, allow_migrations: false)
  end

  # A sqlite database lives in shared/storage and does not exist before the very
  # first deploy, where db:migrate aborts. An external database is somebody
  # else's to create, so there migrate is the only safe verb.
  test "sqlite apps prepare their database, external ones only migrate" do
    sqlite = DeployRecipes.for(app, release_path: "/tmp/r").find { |s| s.key == :migrate }
    external = DeployRecipes.for(app(primary_db_kind: "external"), release_path: "/tmp/r")
                            .find { |s| s.key == :migrate }

    assert_equal %w[bundle exec rails db:prepare], sqlite.argv
    assert_equal %w[bundle exec rails db:migrate], external.argv
  end

  # BUNDLE_* by environment, not `bundle config set --local`: that command writes
  # .bundle/config into the release, which a hardlink-seeded vendor/bundle would
  # carry forward into every later release.
  test "bundler is configured for deployment through the environment" do
    step = DeployRecipes.for(app, release_path: "/tmp/r").first

    assert_equal %w[bundle install --jobs 4], step.argv
    assert_equal "vendor/bundle", step.env["BUNDLE_PATH"]
    assert_equal "true", step.env["BUNDLE_DEPLOYMENT"]
    assert_equal "development:test", step.env["BUNDLE_WITHOUT"]
    # Without clean, a stale default-gem copy survives in the seeded tree and
    # Passenger pre-activates the wrong version on the next cold spawn.
    assert_equal "true", step.env["BUNDLE_CLEAN"]
  end

  # The regression this pins: BUNDLE_* used to hang off `bundle install` alone,
  # so `bundle exec rails db:prepare` and assets:precompile ran with no
  # BUNDLE_PATH. AppShellEnv unsets the manager's own, so bundler looked for the
  # gems in the default location, found nothing that was just installed into
  # vendor/bundle, and every rails deploy died at the migration.
  test "every bundle command in every recipe carries the bundler environment" do
    bundle_steps = every_step.select(&:bundler?)

    assert_operator bundle_steps.size, :>=, 5, "a rails app alone emits five bundle commands across the two gates"
    bundle_steps.each do |step|
      DeployRecipes::BUNDLER_ENV.each do |key, value|
        assert_equal value, step.env_or_empty[key], "step #{step.key} (#{step}) runs without #{key}"
      end
    end
  end

  # The bundler environment is attached by argv, so a step that is not a bundle
  # command keeps exactly the environment its recipe gave it — a php pool must
  # not be told to load gems from vendor/bundle.
  test "steps that are not bundle commands are left alone" do
    steps = every_step.reject(&:bundler?)

    assert steps.none? { |s| s.env_or_empty.key?("BUNDLE_PATH") }
    composer = steps.find { |s| s.key == :composer }
    assert_equal({ "COMPOSER_NO_INTERACTION" => "1" }, composer.env)
  end

  # Recognised by basename so pinning a shim path keeps the configuration, and
  # merged UNDER the step's own env so a recipe can still override one setting.
  test "the bundler environment follows the bundle binary, whatever its path" do
    absolute = DeployRecipes::Step.new(key: :migrate, label: "migrate",
                                       argv: %w[/var/www/vhosts/ltvb.nl/.rbenv/shims/bundle exec rails db:migrate])
    override = DeployRecipes::Step.new(key: :bundle, label: "install",
                                       argv: %w[bundle install], env: { "BUNDLE_WITHOUT" => "test" })

    assert_equal "vendor/bundle", absolute.env["BUNDLE_PATH"]
    assert_equal "test", override.env["BUNDLE_WITHOUT"]
    assert_equal "vendor/bundle", override.env["BUNDLE_PATH"]
  end

  test "the app server restart goes through the privileged wrapper" do
    step = DeployRecipes.for(app, release_path: "/tmp/r").last

    assert step.privileged?
    assert_equal [ "restart-app", "git.ltvb.nl" ], step.argv
  end

  # --- laravel --------------------------------------------------------------

  test "the laravel recipe installs, migrates, caches, links storage and reloads fpm" do
    assert_equal %i[composer migrate config_cache route_cache view_cache storage_link queue_restart fpm_reload],
                 keys_for(laravel_app)
  end

  test "laravel migrations respect the same gate as rails" do
    assert_not_includes keys_for(laravel_app, allow_migrations: false), :migrate
  end

  # A bare `php` on this host can resolve to Plesk's bundled interpreter, whose
  # extension set differs from the FPM pool that will run the code.
  test "artisan runs under the versioned system php that matches the fpm pool" do
    step = DeployRecipes.for(laravel_app, release_path: "/tmp/r").find { |s| s.key == :config_cache }
    assert_equal [ "/usr/bin/php8.3", "artisan", "config:cache", "--no-interaction" ], step.argv
  end

  test "composer installs production dependencies only" do
    step = DeployRecipes.for(laravel_app, release_path: "/tmp/r").first
    assert_includes step.argv, "--no-dev"
    assert_includes step.argv, "--optimize-autoloader"
  end

  test "the fpm reload is privileged and names the pool by fqdn" do
    step = DeployRecipes.for(laravel_app, release_path: "/tmp/r").last
    assert step.privileged?
    assert_equal [ "reload-fpm", "music.ltvb.nl" ], step.argv
  end

  # --- plain php ------------------------------------------------------------

  test "a plain php site only runs composer when there is something to install" do
    a = app(app_kind: "php", ruby_version: nil, php_version: "8.3", doc_root_suffix: "")

    Dir.mktmpdir do |dir|
      assert_equal %i[fpm_reload], DeployRecipes.for(a, release_path: dir).map(&:key)

      File.write(File.join(dir, "composer.json"), "{}")
      assert_equal %i[composer fpm_reload], DeployRecipes.for(a, release_path: dir).map(&:key)
    end
  end

  # PHP-FPM caches the resolved realpath of every included file (120s by
  # default), so without a reload the pool keeps executing the old release after
  # the symlink swap — the swap is only atomic to a visitor once fpm is reloaded.
  test "even a dependency-free php site reloads fpm after the swap" do
    a = app(app_kind: "php", ruby_version: nil, php_version: "8.3", doc_root_suffix: "")
    Dir.mktmpdir { |dir| assert_equal :fpm_reload, DeployRecipes.for(a, release_path: dir).last.key }
  end

  # --- static / cron / repo -------------------------------------------------

  test "a static site has no build steps at all" do
    a = app(app_kind: "static", ruby_version: nil, doc_root_suffix: "")
    assert_empty DeployRecipes.for(a, release_path: "/tmp/r")
  end

  # A cron app has no vhost and no fpm pool to reload, and no public/ to link.
  test "a cron app skips the http-only steps" do
    a = app(app_kind: "cron", subdomain: nil, domain: nil, ruby_version: nil,
            php_version: "8.3", serves_http: false)
    assert_equal %i[composer migrate config_cache queue_restart], keys_for(a)
  end

  test "a repo runs the operator's follow-up commands through a login shell" do
    a = app(app_kind: "repo", deploy_path: "/srv/ui-components", ruby_version: nil,
            post_deploy_commands: "# rebuild\nnpm ci && npm run build\n\n./propagate.sh\n")

    steps = DeployRecipes.for(a, release_path: "/srv/ui-components")

    assert_equal 2, steps.size, "blank lines and comments are not commands"
    assert_equal [ "bash", "-lc", "npm ci && npm run build" ], steps.first.argv
    assert_equal "./propagate.sh", steps.last.label
  end

  # --- shape guarantees -----------------------------------------------------

  # The whole reason steps are data: nothing that varies per app is ever
  # re-parsed by a shell. Only a repo's free-text commands are, and those are
  # the operator's own.
  test "no built recipe smuggles shell syntax into an argument" do
    [ app, laravel_app, app(app_kind: "cron", subdomain: nil, domain: nil, ruby_version: nil, php_version: "8.3") ]
      .each do |a|
        DeployRecipes.for(a, release_path: "/tmp/r").each do |step|
          assert_kind_of Array, step.argv
          step.argv.each do |arg|
            assert_kind_of String, arg
            assert_no_match(/[;&|`$<>()\n]/, arg, "#{step.key} argument #{arg.inspect} looks like shell")
          end
        end
      end
  end

  test "every step carries a key and a human label" do
    DeployRecipes.for(laravel_app, release_path: "/tmp/r").each do |step|
      assert_kind_of Symbol, step.key
      assert step.label.present?
    end
  end

  # --- restart_step ---------------------------------------------------------

  test "restart_step finds the one step that makes a promoted release serve" do
    assert_equal :restart, DeployRecipes.restart_step(app).key
    assert_equal :fpm_reload, DeployRecipes.restart_step(laravel_app).key
  end

  test "restart_step is nil for kinds with nothing to restart" do
    assert_nil DeployRecipes.restart_step(app(app_kind: "static", ruby_version: nil, doc_root_suffix: ""))
    assert_nil DeployRecipes.restart_step(app(app_kind: "cron", subdomain: nil, domain: nil,
                                              ruby_version: nil, php_version: "8.3"))
  end
end
