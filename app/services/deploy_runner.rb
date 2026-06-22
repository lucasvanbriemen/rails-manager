require "open3"
require "fileutils"

# Executes the deploy recipe (the steps learned from fixing git.ltvb.nl), one
# ordered step at a time, streaming all output into the Deployment log. Runs as
# the `ltvb` user (the manager's own Passenger process), shelling out with the
# *target app's* rbenv environment — never the manager's bundler context.
#
#   DeployRunner.new(deployment, ref: nil, upload_tarball: nil).call
class DeployRunner
  class StepFailed < StandardError; end

  def initialize(deployment, ref: nil, upload_tarball: nil)
    @deployment     = deployment
    @app            = deployment.app
    @ref            = ref
    @upload_tarball = upload_tarball
  end

  def call
    @deployment.start!
    log "== #{@deployment.kind} #{@app.fqdn} @ #{Time.current} ==\n"

    case @deployment.kind
    when "create"          then provision!; deploy!
    when "deploy"          then deploy!
    when "restart"         then restart!; verify!
    when "migrate_primary" then migrate_primary!
    when "destroy"         then destroy!
    else raise StepFailed, "unknown kind #{@deployment.kind}"
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
    write_secrets!
    bundle_install!
    prepare_databases!
    precompile_assets!
    restart!
    verify!
  end

  def fetch_code!
    log "\n--- fetch code (#{@app.source_mode}) ---\n"
    if @app.upload?
      unpack_upload!
    elsif Dir.exist?(File.join(@app.app_path, ".git"))
      run! "git", "-C", @app.app_path, "fetch", "--prune", "origin"
      run! "git", "-C", @app.app_path, "reset", "--hard", (@ref.presence || "origin/#{@app.git_branch}")
    else
      FileUtils.mkdir_p(@app.webspace_root)
      run! "git", "clone", "--branch", @app.git_branch, @app.git_repo_url, @app.app_path
    end
    record_git_ref!
  end

  def unpack_upload!
    raise StepFailed, "no upload provided" if @upload_tarball.blank? || !File.exist?(@upload_tarball)

    FileUtils.mkdir_p(@app.app_path)
    run! "tar", "xzf", @upload_tarball, "-C", @app.app_path
    @deployment.update!(ref: "upload")
  end

  def record_git_ref!
    return unless @app.git?

    out, _e, st = capture("git", "-C", @app.app_path, "rev-parse", "HEAD")
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

    env_path = File.join(@app.app_path, ".env")
    File.write(env_path, @app.env_text.to_s)
    File.chmod(0o600, env_path)
    log "wrote .env (#{@app.env_text.to_s.lines.count} lines)\n"
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
    run! "bundle", "exec", "rails", "assets:precompile", extra_env: { "SECRET_KEY_BASE_DUMMY" => "1" }
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
    result = AppStatusChecker.check(@app)
    log "status: #{result[:status]} (HTTP #{result[:code]}) — #{result[:detail]}\n"
    unless AppStatusChecker::HEALTHY.include?(result[:status])
      raise StepFailed, "site not healthy after deploy (#{result[:status]})"
    end
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
    {
      "RBENV_ROOT"        => @app.rbenv_root,
      "PATH"              => "#{@app.rbenv_root}/shims:#{@app.rbenv_root}/bin:/usr/local/bin:/usr/bin:/bin",
      "HOME"              => @app.webspace_root,
      "RAILS_ENV"         => "production",
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

  def stream(cmd, env, chdir)
    Open3.popen2e(env, *cmd, chdir: chdir, unsetenv_others: false) do |stdin, out, wait|
      stdin.close
      out.each_line { |line| @deployment.append_log(line) }
      wait.value.success?
    end
  rescue Errno::ENOENT => e
    @deployment.append_log("command not found: #{e.message}\n")
    false
  end

  def capture(*cmd)
    Open3.capture3(child_env, *cmd, chdir: @app.app_path, unsetenv_others: false)
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
