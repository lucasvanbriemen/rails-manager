# The build steps for each app kind, as DATA rather than shell strings.
#
# WHY argv and not a command line: every value that varies per app (fqdn, php
# version, post-deploy command) reaches a process that this manager runs as a
# webspace owner, and one of those apps' vhosts already carries a RAILS_MASTER_KEY.
# An argv array cannot be re-parsed — a hostname with a `;` in it becomes a
# nonsense argument, not a second command. It also means the recipe is
# inspectable and testable without executing anything, which is the whole reason
# the steps are separate from DeployRunner.
module DeployRecipes
  # How bundler is configured for EVERY `bundle` invocation in a deploy.
  #
  # WHY the environment and not `bundle config set --local`: that command writes
  # .bundle/config INTO the release, and with a hardlink-seeded vendor/bundle the
  # file is carried forward, so a setting outlives the deploy that introduced it.
  # BUNDLE_CLEAN is what drops gems that are no longer in the lock — without it a
  # stale default-gem copy (stringio) survives in the seeded tree and Passenger
  # pre-activates the wrong version, which boots the warm process and kills cold
  # spawns.
  #
  # WHY it must be on every step and not just `bundle install`: AppShellEnv
  # deliberately UNSETS BUNDLE_PATH in the child (it strips the manager's own
  # bundler context), so a `bundle exec rails db:migrate` without this hash looks
  # for gems in the default location, finds none of the ones just installed into
  # vendor/bundle, and the deploy dies at the migration. The same reasoning
  # applies to the process that SERVES the release: with no .bundle/config in the
  # tree, its unit's Environment= is the only other place BUNDLE_PATH can come
  # from.
  BUNDLER_ENV = {
    "BUNDLE_PATH"       => "vendor/bundle",
    "BUNDLE_DEPLOYMENT" => "true",
    "BUNDLE_WITHOUT"    => "development:test",
    "BUNDLE_CLEAN"      => "true"
  }.freeze

  # env:        merged over the child environment (see AppShellEnv) for this step.
  # privileged: argv is a verb + args for PrivilegedShell (sudo ltvb-deployer),
  #             not a command run as the app user.
  Step = Struct.new(:key, :label, :argv, :env, :privileged, keyword_init: true) do
    # Attaching BUNDLER_ENV where the step is BUILT rather than at each call site
    # is what makes the invariant hold: a recipe cannot express a bundle command
    # that runs without the bundler configuration, and a new recipe gets it for
    # free. A step's own env still wins, so a deliberate override is possible.
    def initialize(**attrs)
      super
      self.env = BUNDLER_ENV.merge(env || {}) if bundler?
    end

    # By basename, so pinning an rbenv shim path one day does not silently drop
    # the bundler configuration.
    def bundler? = argv.is_a?(Array) && File.basename(argv.first.to_s) == "bundle"
    def privileged? = !!privileged
    def env_or_empty = env || {}
    def to_s = argv.join(" ")
  end

  # Plesk ships its own PHP under /opt/plesk/php, and a bare `php` on this host
  # can resolve to it — a different build with a different extension set than the
  # FPM pool that will actually run the code. Pin the versioned system binary
  # that matches /etc/php/<v>/fpm.
  def self.php_binary(app)
    app.php_version.presence ? "/usr/bin/php#{app.php_version}" : "php"
  end

  # release_path is where the steps run. It is required rather than optional
  # because one recipe (plain php) has to look at the checkout to decide whether
  # a step exists at all, and silently guessing would be worse than asking.
  #
  # The runner's half of the contract, which the steps themselves cannot enforce:
  #   - cwd is release_path, NOT app.app_path. The release is the only tree that
  #     has the seeded vendor/bundle and the shared/ symlinks; building in the
  #     app root would install into the directory that holds `current`.
  #   - the process runs as app.deploy_user. Only ltvb.nl's apps are `ltvb`; the
  #     other five subscriptions each own their webspace uid, and building as the
  #     wrong user leaves files their own FPM pool cannot rewrite.
  #   - privileged? steps are the exception to both: they are verbs handed to
  #     PrivilegedShell, which runs them as root through the vetted wrapper.
  #
  # allow_migrations defaults to true because that is what happens today (every
  # deploy runs db:prepare); set it false for an app whose database is shared
  # with something else, or whose migrations must be run by hand.
  def self.for(app, release_path:, allow_migrations: true)
    case app.app_kind
    when "rails"   then rails(app, allow_migrations: allow_migrations)
    when "laravel" then laravel(app, allow_migrations: allow_migrations)
    when "cron"    then cron(app, allow_migrations: allow_migrations)
    when "php"     then php(app, release_path)
    when "static"  then []
    when "repo"    then repo(app)
    else                []
    end
  end

  # The step that makes a promoted release actually serve. Promotion calls this
  # after each swap; it is nil for kinds with no server to poke (a static site is
  # read straight off disk, a cron app has no listener).
  def self.restart_step(app)
    self.for(app, release_path: app.app_path).find { |s| [ :restart, :fpm_reload ].include?(s.key) }
  end

  # ---- rails ---------------------------------------------------------------

  def self.rails(app, allow_migrations:)
    steps = [
      # env comes from BUNDLER_ENV, attached by Step to every bundle command.
      Step.new(key: :bundle, label: "bundle install (deployment mode)",
               argv: %w[bundle install --jobs 4])
    ]

    if allow_migrations
      # db:prepare, not db:migrate, when the app owns a sqlite file: the file
      # lives in shared/storage and does not exist before the very first deploy,
      # where db:migrate would abort. An external database is somebody else's to
      # create, so there migrate is the only safe verb.
      task = app.primary_db_kind == "sqlite" ? "db:prepare" : "db:migrate"
      steps << Step.new(key: :migrate, label: "rails #{task}",
                        argv: [ "bundle", "exec", "rails", task ])
    end

    steps << Step.new(key: :assets, label: "rails assets:precompile",
                      argv: %w[bundle exec rails assets:precompile])
    steps << restart_app_step(app)
    steps
  end

  # Restarting is a root operation (systemd), so it goes through the one vetted
  # wrapper rather than being shelled out as the app user.
  def self.restart_app_step(app)
    Step.new(key: :restart, label: "restart app server (#{app.fqdn})",
             argv: [ "restart-app", app.fqdn ], privileged: true)
  end

  # ---- laravel -------------------------------------------------------------

  def self.laravel(app, allow_migrations:)
    php = php_binary(app)
    steps = [ composer_install_step ]
    steps << artisan(php, :migrate, "artisan migrate --force", %w[migrate --force]) if allow_migrations
    steps << artisan(php, :config_cache, "artisan config:cache", %w[config:cache])
    steps << artisan(php, :route_cache,  "artisan route:cache",  %w[route:cache])
    steps << artisan(php, :view_cache,   "artisan view:cache",   %w[view:cache])
    # public/storage is per-release and starts out missing, so this always has
    # work to do — it is not the idempotent no-op it looks like.
    steps << artisan(php, :storage_link, "artisan storage:link", %w[storage:link])
    steps << artisan(php, :queue_restart, "artisan queue:restart", %w[queue:restart])
    steps << fpm_reload_step(app)
    steps
  end

  # Cron-only Laravel apps have no vhost and no FPM pool, so nothing to reload
  # and no public/storage to link — but they do have a database and a queue.
  def self.cron(app, allow_migrations:)
    php = php_binary(app)
    steps = [ composer_install_step ]
    steps << artisan(php, :migrate, "artisan migrate --force", %w[migrate --force]) if allow_migrations
    steps << artisan(php, :config_cache, "artisan config:cache", %w[config:cache])
    steps << artisan(php, :queue_restart, "artisan queue:restart", %w[queue:restart])
    steps
  end

  def self.artisan(php, key, label, args)
    Step.new(key: key, label: label, argv: [ php, "artisan", *args, "--no-interaction" ])
  end

  def self.composer_install_step
    Step.new(key: :composer, label: "composer install (no dev, optimized autoloader)",
             argv: %w[composer install --no-dev --optimize-autoloader --no-interaction --no-progress --prefer-dist],
             env: { "COMPOSER_NO_INTERACTION" => "1" })
  end

  # ---- plain php -----------------------------------------------------------

  def self.php(app, release_path)
    steps = []
    steps << composer_install_step if File.exist?(File.join(release_path.to_s, "composer.json"))
    # Even a dependency-free PHP site needs this. PHP-FPM caches the resolved
    # realpath of every included file (realpath_cache_ttl, 120s by default) and
    # opcache keys compiled scripts by that path, so after the `current` symlink
    # moves the pool keeps executing the OLD release for up to two minutes. The
    # swap is only atomic from a visitor's point of view once the pool is
    # reloaded, which is why this is part of the recipe rather than optional.
    steps << fpm_reload_step(app)
    steps
  end

  def self.fpm_reload_step(app)
    Step.new(key: :fpm_reload, label: "reload php-fpm pool (#{app.fqdn})",
             argv: [ "reload-fpm", app.fqdn ], privileged: true)
  end

  # ---- repo ----------------------------------------------------------------

  # A repo (ui-components) keeps today's behaviour exactly: DeployRunner pulls it
  # in place and then runs the operator's own follow-up command lines. Those are
  # free-text and use shell syntax (&&, pipes), so unlike every other recipe they
  # are deliberately handed to a login shell — the login shell is also what makes
  # nvm/node and rbenv resolve.
  def self.repo(app)
    app.post_deploy_command_list.each_with_index.map do |command, i|
      Step.new(key: :"post_deploy_#{i + 1}", label: command, argv: [ "bash", "-lc", command ])
    end
  end
end
