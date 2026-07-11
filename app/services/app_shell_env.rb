# Child-process environments for shelling into a managed app's checkout.
# Shared by DeployRunner (build/deploy commands) and ConsoleRunner (rails
# console): the target app's rbenv on PATH, production, and the MANAGER's own
# bundler/ruby context stripped out (nil unsets the var in the child).
module AppShellEnv
  MANAGER_RUBY_CONTEXT = {
    "BUNDLE_GEMFILE"    => nil,
    "BUNDLE_PATH"       => nil,
    "BUNDLE_APP_CONFIG" => nil,
    "BUNDLE_WITHOUT"    => nil,
    "RUBYOPT"           => nil,
    "RUBYLIB"           => nil,
    "GEM_HOME"          => nil,
    "GEM_PATH"          => nil
  }.freeze

  # Env for a rails app. dummy_secret: build-phase tasks (db:*,
  # assets:precompile) just need the app to boot, not real credentials — a
  # console must NOT set it, so it can decrypt the real ones.
  def self.rails(app, extra = {}, dummy_secret: false)
    env = MANAGER_RUBY_CONTEXT.merge(
      "RBENV_ROOT" => app.rbenv_root,
      "PATH"       => "#{app.rbenv_root}/shims:#{app.rbenv_root}/bin:/usr/local/bin:/usr/bin:/bin",
      "HOME"       => app.webspace_root,
      "RAILS_ENV"  => "production"
    )
    env["SECRET_KEY_BASE_DUMMY"] = "1" if dummy_secret
    env.merge(extra)
  end

  # Repos build with the ltvb user's normal environment (its real HOME, so
  # nvm/node, npm caches and git/ssh credentials resolve), minus the manager's
  # own bundler/ruby context. No rbenv, RAILS_ENV, or dummy secret — not Rails.
  def self.repo(extra = {})
    MANAGER_RUBY_CONTEXT.merge(extra)
  end
end
