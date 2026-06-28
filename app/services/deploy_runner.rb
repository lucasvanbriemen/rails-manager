require "open3"
require "fileutils"
require "bundler"

# Executes the deploy recipe (the steps learned from fixing git.ltvb.nl), one
# ordered step at a time, streaming all output into the Deployment log. Runs as
# the `ltvb` user (the manager's own Passenger process), shelling out with the
# *target app's* rbenv environment — never the manager's bundler context.
#
#   DeployRunner.new(deployment, ref: nil).call
class DeployRunner
  class StepFailed < StandardError; end

  def initialize(deployment, ref: nil)
    @deployment     = deployment
    @app            = deployment.app
    @ref            = ref
  end

  def call
    @deployment.start!
    log "== #{@deployment.kind} #{@app.repo? ? @app.name : @app.fqdn} @ #{Time.current} ==\n"

    if (reason = @app.undeployable_reason)
      raise StepFailed, "refusing to deploy #{@app.name}: #{reason}"
    end

    if @app.repo?
      run_repo!
    else
      case @deployment.kind
      when "create"          then provision!; deploy!
      when "deploy"          then deploy!
      when "restart"         then restart!; verify!
      when "migrate_primary" then migrate_primary!
      when "destroy"         then destroy!
      else raise StepFailed, "unknown kind #{@deployment.kind}"
      end
    end

    @deployment.finish!(true)
    log "\n== success ==\n"
    true
  rescue StepFailed => e
    log "\n== FAILED: #{e.message} ==\n"
    @deployment.finish!(false)
    false
  rescue StandardError => e
    log "\n== ERROR: #{e.class}: #{e.message} ==\n#{e.backtrace.first(5).join("\n")}\n"
    @deployment.finish!(false)
    false
  end

  private

  # ---- repo recipe ---------------------------------------------------------

  # A plain git repo (e.g. ui-components): pull to its custom path, optionally
  # write a .env, then run the configured follow-up commands. No Plesk, Ruby,
  # bundle, assets, Passenger, or health check — none of that applies.
  def run_repo!
    return repo_destroy! if @deployment.kind == "destroy"

    git_sync!
    record_git_ref!
    write_secrets!
    run_post_deploy_commands!
  end

  def run_post_deploy_commands!
    commands = @app.post_deploy_command_list
    if commands.empty?
      log "\n--- no follow-up commands configured ---\n"
      return
    end

    log "\n--- follow-up commands (#{commands.size}) ---\n"
    commands.each { |cmd| run_shell! cmd }
  end

  # A repo isn't a Plesk subdomain — there's nothing to remove on the server.
  # The on-disk checkout is left in place; the manager just stops tracking it.
  def repo_destroy!
    log "\n--- stop managing repo (on-disk checkout left at #{@app.app_path}) ---\n"
  end

  # ---- recipe phases -------------------------------------------------------

  def provision!
    log "\n--- provision Plesk subdomain ---\n"
    plesk "create subdomain", Plesk.create_subdomain(@app.subdomain, @app.domain)
    plesk "set document root to #{@app.relative_www_root}",
          Plesk.set_docroot(@app.subdomain, @app.domain, @app.relative_www_root)
    plesk "enable Passenger/Ruby #{@app.ruby_version}",
          Plesk.enable_ruby(@app.fqdn, @app.ruby_version)
    plesk "reconfigure apache vhost", Plesk.reconfigure(@app.fqdn)
  end

  def deploy!
    fetch_code!
    clean_placeholder!
    write_secrets!
    bundle_install!
    prepare_databases!
    precompile_assets!
    restart!
    verify!
  end

  def fetch_code!
    log "\n--- fetch code (#{@app.source_mode}) ---\n"
    git_sync!
    record_git_ref!
  end

  # Bring the on-disk code to the target git ref. Handles three cases: an
  # existing checkout (fetch+reset), an existing NON-git deploy (adopt in place,
  # preserving untracked .env/master.key/vendor/storage), and a fresh dir.
  def git_sync!
    target = @ref.presence || "origin/#{@app.git_branch}"

    if Dir.exist?(File.join(@app.app_path, ".git"))
      git! "remote", "set-url", "origin", @app.git_repo_url
    else
      log "initializing git checkout in #{@app.app_path}\n" unless Dir.exist?(@app.app_path)
      log "adopting existing directory as a git checkout\n" if Dir.exist?(@app.app_path)
      FileUtils.mkdir_p(@app.app_path)
      git! "init", "-q", "-b", @app.git_branch
      git! "remote", "add", "origin", @app.git_repo_url
    end

    git! "fetch", "--prune", "origin"
    git! "reset", "--hard", target
  end

  # Run git against the app's on-disk checkout. The checkout may have been
  # created by a different user than the worker (`ltvb`) — an adopted directory,
  # or one chowned by Plesk — so mark the path safe per-invocation. This avoids
  # git's "dubious ownership" abort without touching any user's global gitconfig.
  def git!(*args)
    run! "git", "-c", "safe.directory=#{@app.app_path}", "-C", @app.app_path, *args
  end

  # Plesk seeds a new docroot with its "Domain Default page" index.html. With
  # Passenger on, a public/index.html shadows the Rails root — so the site shows
  # the placeholder forever. Remove it (only when it's actually the Plesk page).
  def clean_placeholder!
    [ File.join(@app.public_path, "index.html"), File.join(@app.app_path, "index.html") ].each do |f|
      next unless File.exist?(f)
      next unless File.read(f).include?("Domain Default page")

      File.delete(f)
      log "removed Plesk placeholder #{f}\n"
    end
  end

  def record_git_ref!
    return unless @app.git?

    out, _e, st = capture("git", "-c", "safe.directory=#{@app.app_path}", "-C", @app.app_path, "rev-parse", "HEAD")
    @deployment.update!(ref: out.strip) if st&.success?
  end

  # Write secrets the app needs to boot — the two things missing on git.ltvb.nl.
  def write_secrets!
    log "\n--- write secrets (.env, master.key) ---\n"
    FileUtils.mkdir_p(File.join(@app.app_path, "config"))

    if @app.master_key.present?
      path = File.join(@app.app_path, "config", "master.key")
      File.write(path, @app.master_key)
      File.chmod(0o600, path)
      log "wrote config/master.key\n"
    else
      log "no master.key stored — skipping (credentials must not be needed to boot)\n"
    end

    if @app.env_text.present?
      env_path = File.join(@app.app_path, ".env")
      File.write(env_path, @app.env_text)
      File.chmod(0o600, env_path)
      log "wrote .env (#{@app.env_text.lines.count} lines)\n"
    else
      log "no .env stored — leaving any existing .env untouched\n"
    end
  end

  def bundle_install!
    log "\n--- bundle install (rbenv #{@app.ruby_version}) ---\n"
    ensure_ruby_installed!
    run! "bundle", "config", "set", "--local", "path", "vendor/bundle"
    run! "bundle", "config", "set", "--local", "without", "development:test"
    run! "bundle", "install", "--jobs", "4"
  end

  def prepare_databases!
    log "\n--- prepare databases ---\n"
    if @app.external_primary?
      log "primary DB is external/shared — NOT migrating it (use the guarded action). Secondary DBs only.\n"
      %w[cache queue cable].each do |db|
        run! "bundle", "exec", "rails", "db:create:#{db}", "db:migrate:#{db}"
      end
    else
      run! "bundle", "exec", "rails", "db:prepare"
    end
  end

  def precompile_assets!
    log "\n--- assets:precompile ---\n"
    run! "bundle", "exec", "rails", "assets:precompile"
  end

  def restart!
    log "\n--- restart Passenger ---\n"
    tmp = File.join(@app.app_path, "tmp")
    FileUtils.mkdir_p(tmp)
    FileUtils.touch(File.join(tmp, "restart.txt"))
    log "touched tmp/restart.txt\n"
  end

  def migrate_primary!
    log "\n--- migrate primary DB (explicit) ---\n"
    run! "bundle", "exec", "rails", "db:migrate:status:primary"
    run! "bundle", "exec", "rails", "db:migrate:primary"
  end

  def destroy!
    log "\n--- remove Plesk subdomain ---\n"
    plesk "remove subdomain", Plesk.remove_subdomain(@app.subdomain, @app.domain)
  end

  def verify!
    log "\n--- verify live site ---\n"
    result = wait_for_health
    return if AppStatusChecker::HEALTHY.include?(result[:status])

    # Most common boot failure on this server is the Passenger default-gem
    # (stringio) conflict. Try to self-heal once, then re-verify.
    log "not healthy (#{result[:status]}: #{result[:detail]}) — attempting stringio heal\n"
    heal_stringio!
    restart!
    result = wait_for_health
    return if AppStatusChecker::HEALTHY.include?(result[:status])

    raise StepFailed, "site not healthy after deploy + heal (#{result[:status]}: #{result[:detail]})"
  end

  # Passenger cold-spawns on the first request after a restart, so poll a few
  # times rather than failing on a single early check.
  def wait_for_health(tries: 6, delay: 2)
    result = nil
    tries.times do |i|
      result = AppStatusChecker.check(@app)
      log "  check #{i + 1}/#{tries}: #{result[:status]} (HTTP #{result[:code]})\n"
      return result if AppStatusChecker::HEALTHY.include?(result[:status])

      sleep delay
    end
    result
  end

  # Pin stringio to the Ruby default so Passenger's pre-activated version matches
  # the lock, then drop any stale newer copy. Idempotent.
  def heal_stringio!
    default = capture("ruby", "-e", "require 'stringio'; print StringIO::VERSION").first.to_s.strip
    default = "3.1.1" if default.empty?
    gemfile = File.join(@app.app_path, "Gemfile")
    if File.read(gemfile).match?(/^\s*gem ["']stringio["']/)
      log "stringio already pinned; refreshing bundle\n"
    else
      File.open(gemfile, "a") { |f| f.puts %(gem "stringio", "#{default}") }
      log "pinned stringio #{default} in Gemfile (Passenger default-gem workaround)\n"
    end
    run! "bundle", "config", "set", "--local", "frozen", "false"
    run! "bundle", "install", "--jobs", "4"
    run! "bundle", "clean", "--force"
  end

  # ---- ruby / rbenv --------------------------------------------------------

  def ensure_ruby_installed!
    version_dir = File.join(@app.rbenv_root, "versions", @app.ruby_version)
    return if Dir.exist?(version_dir)

    raise StepFailed,
          "Ruby #{@app.ruby_version} is not installed for this webspace " \
          "(#{version_dir} missing). Install it via the Plesk Ruby extension, then retry."
  end

  # ---- shell plumbing ------------------------------------------------------

  # Child env: target app's rbenv on PATH, production, and the manager's own
  # bundler/ruby context stripped out (nil unsets the var in the child).
  def child_env(extra = {})
    return repo_env(extra) if @app.repo?

    {
      "RBENV_ROOT"        => @app.rbenv_root,
      "PATH"              => "#{@app.rbenv_root}/shims:#{@app.rbenv_root}/bin:/usr/local/bin:/usr/bin:/bin",
      "HOME"              => @app.webspace_root,
      "RAILS_ENV"         => "production",
      # Build-phase rails tasks (db:*, assets:precompile) just need the app to
      # boot, not a real secret. Apps that read RAILS_MASTER_KEY from Apache
      # (e.g. login) have no key in this shell, so use a throwaway one here.
      # The real key is only used by the serving Passenger process.
      "SECRET_KEY_BASE_DUMMY" => "1",
      "BUNDLE_GEMFILE"    => nil,
      "BUNDLE_PATH"       => nil,
      "BUNDLE_APP_CONFIG" => nil,
      "BUNDLE_WITHOUT"    => nil,
      "RUBYOPT"           => nil,
      "RUBYLIB"           => nil,
      "GEM_HOME"          => nil,
      "GEM_PATH"          => nil
    }.merge(extra)
  end

  # Repos build with the ltvb user's normal environment (its real HOME, so
  # nvm/node, npm caches and git/ssh credentials resolve), minus the manager's
  # own bundler/ruby context. No rbenv, RAILS_ENV, or dummy secret — not Rails.
  def repo_env(extra = {})
    {
      "BUNDLE_GEMFILE"    => nil,
      "BUNDLE_PATH"       => nil,
      "BUNDLE_APP_CONFIG" => nil,
      "BUNDLE_WITHOUT"    => nil,
      "RUBYOPT"           => nil,
      "RUBYLIB"           => nil,
      "GEM_HOME"          => nil,
      "GEM_PATH"          => nil
    }.merge(extra)
  end

  def run!(*cmd, extra_env: {})
    log "\n$ #{cmd.join(' ')}\n"
    ok = stream(cmd, child_env(extra_env), @app.app_path)
    raise StepFailed, cmd.first(3).join(" ") unless ok
  end

  # A user-entered command line, run through a login shell so the ltvb user's
  # profile (nvm/node, rbenv, PATH) is sourced and shell syntax (&&, |) works.
  def run_shell!(command)
    log "\n$ #{command}\n"
    ok = stream([ "bash", "-lc", command ], child_env, @app.app_path)
    raise StepFailed, command unless ok
  end

  # with_unbundled_env strips the MANAGER's bundler context (RUBYOPT=-rbundler/setup,
  # BUNDLE_GEMFILE, GEM_*) so the child uses the TARGET app's bundler, not ours.
  def stream(cmd, env, chdir)
    Bundler.with_unbundled_env do
      Open3.popen2e(env, *cmd, chdir: chdir, unsetenv_others: false) do |stdin, out, wait|
        stdin.close
        out.each_line { |line| @deployment.append_log(line) }
        wait.value.success?
      end
    end
  rescue Errno::ENOENT => e
    @deployment.append_log("command not found: #{e.message}\n")
    false
  end

  def capture(*cmd)
    Bundler.with_unbundled_env do
      Open3.capture3(child_env, *cmd, chdir: @app.app_path, unsetenv_others: false)
    end
  rescue StandardError
    [ "", "", nil ]
  end

  def plesk(label, result)
    @deployment.append_log(result.output + "\n") if result.output.present?
    raise StepFailed, "#{label}: #{result.err.presence || 'failed'}" unless result.ok

    log "✓ #{label}\n"
  end

  def log(msg)
    @deployment.append_log(msg)
  end
end
