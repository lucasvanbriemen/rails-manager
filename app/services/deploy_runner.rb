require "open3"
require "fileutils"
require "bundler"
require "etc"

# Runs one Deployment, step by ordered step, streaming every line of output into
# the Deployment log.
#
# There are two strategies and an app picks one:
#
#   in_place  builds in the directory the web server is already serving:
#             `git reset --hard`, bundle, migrate, precompile, restart. Any
#             failure between the first step and the last leaves a half-built
#             LIVE site. This is what every app did before atomic releases
#             existed, and it stays the default so nothing moves under an app
#             until somebody deliberately switches it.
#
#   atomic    checks out a NEW release directory beside the old ones, builds it,
#             health-checks it and only then moves the `current` symlink — one
#             rename(2), see ReleaseLayout#swap!. A build that fails never
#             reaches `current`; a release that fails its health check is
#             swapped straight back off. See ReleaseLayout for the on-disk
#             shape, DeployRecipes for the per-kind build steps and Release for
#             which directory is allowed to be a rollback target.
#
# DELIBERATELY GONE: `heal_stringio!`. When a deploy failed its health check the
# old runner appended `gem "stringio", "<ruby's default>"` to the app's own
# tracked Gemfile, re-bundled and tried again. It existed because Passenger
# pre-activates its own default gems and a stale copy in vendor/bundle lost that
# argument. It is not coming back, for two independent reasons. The conflict
# cannot arise under a per-release bundle: BUNDLE_PATH points inside the release
# and BUNDLE_CLEAN drops everything not in the lock, so there is no stale copy to
# pre-activate (DeployRecipes::BUNDLER_ENV, and the comment there). And a deploy
# tool that edits the repository it is deploying is a trap whatever the payoff —
# the next `git reset --hard` silently reverts the "fix" so the failure returns
# with no trace of the attempt, the change never appears in review, and nobody
# can reason about what a given commit deploys to. If a Passenger default-gem
# conflict ever shows up again, it gets fixed in the Gemfile by a human, in a
# commit.
class DeployRunner
  class StepFailed < StandardError; end

  ATOMIC     = "atomic".freeze
  IN_PLACE   = "in_place".freeze
  STRATEGIES = [ IN_PLACE, ATOMIC ].freeze

  # Recipe steps the BUILD must not run. Restarting the app server is what makes
  # a release serve traffic, so it belongs after the swap — ReleaseLayout::
  # Promotion calls it, once per swap, including the rollback's.
  PROMOTION_STEP_KEYS = %i[restart fpm_reload].freeze

  # The bare mirror clone, beside releases/ and shared/ in the app root.
  MIRROR_DIR = "repo".freeze

  # Where `git archive` writes before extraction. One fixed name is safe: the
  # deploy lock guarantees one build per app at a time.
  CHECKOUT_TAR = ".release.tar".freeze

  # Which app attribute holds each shared secret. Driven by ReleaseLayout's
  # shared_files so a kind that has no master.key never gets an orphan one.
  SHARED_SECRETS = { ".env" => :env_text, "config/master.key" => :master_key }.freeze

  # shell:        runs commands as the app's own user (see Shell)
  # privileged:   the one root-privileged surface; anything responding to
  #               #run(verb, *args) => PrivilegedShell::Result
  # health_check: owns both the probe and the polling policy (DeployHealthCheck)
  def initialize(deployment, ref: nil, shell: nil, privileged: nil, health_check: nil, now: Time.current)
    @deployment   = deployment
    @app          = deployment.app
    @ref          = ref
    @now          = now
    @health_check = health_check
    @privileged   = privileged || PrivilegedShell
    @shell        = shell || Shell.new(user: @app.deploy_user,
                                       on_output: ->(line) { @deployment.append_log(line) })
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
      when "destroy"         then destroy!
      else raise StepFailed, "unknown kind #{@deployment.kind}"
      end
    end

    restart_jobs_worker! if manager_self_deploy? && @deployment.kind != "destroy"

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

  # ---- strategy ------------------------------------------------------------

  # in_place unless the app was deliberately switched AND its kind can carry the
  # release layout. A repo (ui-components) is a flat checkout that other apps
  # mount by path; giving it a `current` symlink would break every consumer's
  # include path, so the kind vetoes the setting rather than the setting winning.
  def strategy
    @strategy ||= begin
      requested = @app.deploy_strategy.to_s
      if requested != ATOMIC
        IN_PLACE
      elsif !ReleaseLayout.applies_to?(@app)
        log "atomic releases do not apply to a #{@app.app_kind} app — deploying in place\n"
        IN_PLACE
      else
        ATOMIC
      end
    end
  end

  private

  def deploy!
    ensure_deploy_user!
    log "\n--- deploy strategy: #{strategy} ---\n"
    strategy == ATOMIC ? atomic_deploy! : in_place_deploy!
  end

  # ---- atomic releases -----------------------------------------------------

  def atomic_deploy!
    layout = ReleaseLayout.new(@app, now: @now)
    log "\n--- atomic release under #{layout.root} ---\n"

    layout.with_deploy_lock do
      prepare_layout!(layout)
      promote!(layout, build_release!(layout))
    end
  rescue ReleaseLayout::Locked => e
    raise StepFailed, e.message
  rescue SystemCallError => e
    # The swap and the shared secrets are written by THIS process — rename(2) is
    # a single syscall and stops being atomic the moment it is handed to a
    # helper — so the manager's own uid has to own the app root. It does inside
    # its own webspace. Anywhere else the honest answer is this message, not a
    # backtrace.
    raise StepFailed, "#{e.message} — the atomic path writes releases/, shared/ and the `current` " \
                      "symlink as #{Shell.current_user}, which must therefore own #{@app.app_path}"
  end

  def prepare_layout!(layout)
    FileUtils.mkdir_p(layout.releases_path)
    FileUtils.mkdir_p(layout.shared_skeleton)
  end

  # Build a release directory and leave it entirely unpublished. Nothing in here
  # can change what the site serves; that is the whole point.
  def build_release!(layout)
    path    = layout.new_release_path
    release = record_release(path)
    started = monotonic

    begin
      sha = checkout_release!(layout, path)
      release.update!(git_ref: sha)
      @deployment.update!(ref: sha)
      write_shared_secrets!(layout)
      link_shared!(layout, path)
      seed_caches!(layout, path)
      run_build_steps!(path)
    rescue StandardError
      # `current` has not moved, so the previous release is still serving. The
      # directory stays on disk on purpose: it is the only evidence of what went
      # wrong, and Release.prunable retires it on a later deploy.
      release.mark_failed!
      log "\n--- build failed; #{layout.current_target || 'nothing'} is still serving ---\n"
      raise
    end

    release.record_build!(duration_ms: ((monotonic - started) * 1000).round)
    release
  end

  # find_or_initialize, not create: a job retried inside the same second resolves
  # to the same release name, and a uniqueness failure there would look like a
  # broken deploy instead of the retry it is.
  def record_release(path)
    release = @app.releases.find_or_initialize_by(path: path)
    release.update!(deployment: @deployment, git_branch: @app.git_branch,
                    status: Release::BUILDING, git_ref: nil, deployed_at: nil, superseded_at: nil)
    release
  end

  def checkout_release!(layout, path)
    log "\n--- fetch code ---\n"
    mirror = File.join(layout.root, MIRROR_DIR)
    sync_mirror!(layout, mirror)
    sha = resolve_ref!(mirror)
    log "checking out #{sha}\n"
    extract!(layout, mirror, sha, path)
    sha
  end

  # A bare mirror beside the releases. Every release is then extracted from local
  # objects instead of cloning the repository over the network again, and a
  # rollback-and-redeploy still works while GitHub is unreachable.
  def sync_mirror!(layout, mirror)
    if Dir.exist?(File.join(mirror, "objects"))
      run! [ "git", "-C", mirror, "remote", "set-url", "origin", @app.git_repo_url ], chdir: layout.root
      run! [ "git", "-C", mirror, "remote", "update", "--prune" ], chdir: layout.root
    else
      FileUtils.rm_rf(mirror)
      run! [ "git", "clone", "--mirror", @app.git_repo_url, mirror ], chdir: layout.root
    end
  end

  # In a mirror the branches are refs/heads/<branch>, so `origin/main` does NOT
  # resolve — and `origin/main` is exactly what the in-place path passes around.
  # Accept every spelling a caller plausibly sends and, when none of them exist,
  # say which were tried instead of leaving git's "unknown revision" to explain.
  def resolve_ref!(mirror)
    ref_candidates.each do |candidate|
      result = @shell.capture([ "git", "-C", mirror, "rev-parse", "--verify", "--quiet", "#{candidate}^{commit}" ],
                              env: child_env, chdir: mirror)
      sha = result.out.to_s.strip
      return sha if result.ok && sha.present?
    end

    raise StepFailed, "no such ref in #{@app.git_repo_url} (tried #{ref_candidates.join(', ')})"
  end

  def ref_candidates
    @ref_candidates ||= if @ref.present?
      [ @ref.to_s, @ref.to_s.delete_prefix("origin/") ].uniq
    else
      [ @app.git_branch, "origin/#{@app.git_branch}" ]
    end
  end

  # WHY archive-and-extract rather than a checkout: a release must be a plain
  # directory of files with no .git in it. Nothing inside a release may be able
  # to change what it contains once it has been health-checked and promoted, and
  # a release with no remote makes a stray `git pull` in a live directory —
  # the exact accident atomic releases exist to survive — impossible.
  def extract!(layout, mirror, sha, path)
    tar = File.join(layout.root, CHECKOUT_TAR)
    FileUtils.mkdir_p(path)
    run! [ "git", "-C", mirror, "archive", "--format=tar", "-o", tar, sha ], chdir: layout.root
    run! [ "tar", "-xf", tar, "-C", path ], chdir: layout.root
  ensure
    FileUtils.rm_f(tar) if tar
  end

  # Secrets live in shared/ and are symlinked into every release, so they survive
  # a deploy and a rollback alike. A blank value leaves whatever is already there
  # alone — an app whose .env was hand-written on the server must not be wiped by
  # a manager that never learned it.
  def write_shared_secrets!(layout)
    log "\n--- write secrets into #{layout.shared_path} ---\n"

    layout.shared_files.each do |rel|
      attribute = SHARED_SECRETS[rel]
      next unless attribute

      value = @app.public_send(attribute)
      if value.blank?
        log "no #{rel} stored — leaving any existing file untouched\n"
        next
      end

      path = File.join(layout.shared_path, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, value)
      File.chmod(0o600, path)
      log "wrote shared/#{rel}\n"
    end
  end

  def link_shared!(layout, path)
    links = layout.links(path)
    return if links.empty?

    log "\n--- link shared state ---\n"
    links.each do |link|
      FileUtils.mkdir_p(File.dirname(link.link))
      # The checkout may ship a log/.keep or an empty storage/. The shared copy
      # is the one whose inode has to survive the deploy, so git's version goes.
      FileUtils.rm_rf(link.link)
      File.symlink(link.target, link.link)
      log "#{link.link} -> #{link.target}\n"
    end
  end

  # Hardlink the previous build cache into this release (see ReleaseLayout#
  # seeded_dirs for why hardlinks and not a shared symlink).
  def seed_caches!(layout, path)
    seeds = layout.seeds(path).select { |seed| Dir.exist?(seed.source) && !File.exist?(seed.dest) }
    return if seeds.empty?

    log "\n--- seed build caches ---\n"
    seeds.each do |seed|
      FileUtils.mkdir_p(File.dirname(seed.dest))
      FileUtils.cp_lr(seed.source, seed.dest)
      log "#{seed.dest} <- #{seed.source}\n"
    end
  end

  # Point the shared cache at the release that just went live, so the NEXT
  # deploy's seeding starts warm instead of re-downloading every gem. Hardlinks
  # again: this costs directory entries, not a gigabyte. Non-fatal by design — a
  # cold cache is slow, not broken, and the site is already serving.
  def refresh_seed_caches!(layout, release_path)
    layout.seeds(release_path).each do |seed|
      next unless Dir.exist?(seed.dest)

      FileUtils.rm_rf(seed.source)
      FileUtils.mkdir_p(File.dirname(seed.source))
      FileUtils.cp_lr(seed.dest, seed.source)
    end
  rescue SystemCallError => e
    log "WARN: could not refresh the shared build cache (#{e.message})\n"
  end

  def run_build_steps!(path)
    steps = DeployRecipes.for(@app, release_path: path).reject { |step| PROMOTION_STEP_KEYS.include?(step.key) }
    if steps.empty?
      log "\n--- nothing to build for a #{@app.app_kind} app ---\n"
      return
    end

    steps.each { |step| run_step!(step, chdir: path) }
  end

  def promote!(layout, release)
    # Ask BEFORE the swap. Right now the row still flagged LIVE is the code
    # actually serving traffic, which is precisely what makes it a legal
    # rollback target; after the swap it is not.
    previous = Release.rollback_target(@app)
    log "\n--- promote #{release.name} (rollback target: #{previous&.name || 'none'}) ---\n"

    result = ReleaseLayout::Promotion.new(
      layout: layout,
      release_path: release.path,
      previous_path: previous&.path,
      health: -> { health_check.probe.to_h },
      restart: -> { restart_app!(layout) },
      logger: ->(message) { log message },
      # Promotion polls #probe itself, so it borrows the health check's own
      # policy rather than keeping a second one that could disagree about how
      # long a restart is allowed to take.
      tries: health_check.tries, delay: health_check.delay, sleeper: health_check.sleeper
    ).call

    return finish_promotion!(layout, release) if result.ok?

    if result.rolled_back?
      # Order matters: the bad release stops being LIVE first, so re-promoting
      # the old one cannot be recorded as a clean supersede (see Release#mark_live!).
      release.mark_rolled_back!
      previous&.mark_live!
    else
      # Nothing to fall back to, so `current` really does point at this release
      # and the table has to say so. Calling it FAILED would claim it never
      # shipped while the site is serving it.
      release.mark_live!
    end

    raise StepFailed, "health check failed: #{result.detail}"
  end

  def finish_promotion!(layout, release)
    release.mark_live!
    log "\n--- #{release.name} is live ---\n"
    refresh_seed_caches!(layout, release.path)
  end

  # What makes a swapped release actually serve. Two mechanisms coexist while
  # this box is mid-migration off Plesk: Passenger reloads when tmp/restart.txt
  # changes, and the recipes ask the privileged wrapper for a systemd restart or
  # an FPM pool reload. Do the Passenger one first (a file write, it cannot
  # fail), then the recipe's step if there is one — treating a wrapper that does
  # not implement the verb yet as a warning rather than a failed deploy, because
  # the health check immediately after is the real gate: a server that never
  # restarted still answers with the old code and fails it.
  def restart_app!(layout)
    touch_passenger_restart!(layout)
    step = DeployRecipes.restart_step(@app)
    return unless step

    result = @privileged.run(*step.argv)
    log(result.output + "\n") if result.output.present?
    log "WARN: #{step.label} failed (#{result.err.presence || 'failed'})\n" unless result.ok
  end

  # Through `current`, so this touches whichever release is serving right now —
  # including after a rollback has put the old one back.
  def touch_passenger_restart!(layout)
    return unless @app.ruby?

    tmp = File.join(layout.current_path, "tmp")
    FileUtils.mkdir_p(tmp)
    FileUtils.touch(File.join(tmp, "restart.txt"))
    log "touched current/tmp/restart.txt\n"
  rescue SystemCallError => e
    log "WARN: could not touch current/tmp/restart.txt (#{e.message})\n"
  end

  # ---- repo recipe ---------------------------------------------------------

  # A plain git repo (e.g. ui-components): pull to its custom path, optionally
  # write a .env, then run the configured follow-up commands. No Plesk, Ruby,
  # bundle, assets, Passenger, or health check — none of that applies.
  def run_repo!
    return repo_destroy! if @deployment.kind == "destroy"

    ensure_deploy_user!
    git_sync!
    record_git_ref!
    write_secrets!
    run_post_deploy_commands!
  end

  def run_post_deploy_commands!
    steps = DeployRecipes.for(@app, release_path: @app.app_path)
    if steps.empty?
      log "\n--- no follow-up commands configured ---\n"
      return
    end

    log "\n--- follow-up commands (#{steps.size}) ---\n"
    steps.each { |step| run_step!(step, chdir: @app.app_path) }
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

  # Today's deploy, unchanged: every step runs in the directory the web server is
  # serving, so a failure anywhere in the middle is visible to the internet. Kept
  # because it is what every app is still configured for, and because switching
  # an app to atomic releases moves its code to app_path/current and needs its
  # vhost repointed in the same change.
  def in_place_deploy!
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
    log "\n--- fetch code for git ---\n"
    git_sync!
    record_git_ref!
  end

  # Bring the on-disk code to the target git ref. Handles three cases: an
  # existing checkout (fetch+reset), an existing NON-git deploy (adopt in place,
  # preserving untracked .env/master.key/vendor/storage), and a fresh dir.
  def git_sync!
    target = @ref.presence || "origin/#{@app.git_branch}"

    if Dir.exist?(File.join(@app.app_path, ".git"))
      set_origin!
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

  # Point origin at the configured URL. An existing .git may have been created by
  # `git init` without a remote (or with a differently-named one), so add origin
  # when it's missing rather than assuming `set-url` will find it.
  def set_origin!
    if git_remotes.include?("origin")
      git! "remote", "set-url", "origin", @app.git_repo_url
    else
      git! "remote", "add", "origin", @app.git_repo_url
    end
  end

  def git_remotes
    capture("git", "-c", "safe.directory=#{@app.app_path}", "-C", @app.app_path, "remote").out.to_s.split
  end

  # Run git against the app's on-disk checkout. The checkout may have been
  # created by a different user than the worker — an adopted directory, or one
  # chowned by Plesk — so mark the path safe per-invocation. This avoids git's
  # "dubious ownership" abort without touching any user's global gitconfig.
  def git!(*args)
    run! [ "git", "-c", "safe.directory=#{@app.app_path}", "-C", @app.app_path, *args ], chdir: @app.app_path
  end

  # Plesk seeds a new docroot with its "Domain Default page" index.html. With
  # Passenger on, a public/index.html shadows the Rails root — so the site shows
  # the placeholder forever. Remove it (only when it's actually the Plesk page).
  def clean_placeholder!
    [ File.join(@app.public_path, "index.html"), File.join(@app.app_path, "index.html") ].each do |f|
      next unless File.exist?(f)
      next unless File.read(f).include?(DeployHealthCheck::PLACEHOLDER)

      File.delete(f)
      log "removed Plesk placeholder #{f}\n"
    end
  end

  def record_git_ref!
    result = capture("git", "-c", "safe.directory=#{@app.app_path}", "-C", @app.app_path, "rev-parse", "HEAD")
    @deployment.update!(ref: result.out.strip) if result.ok
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
    run! %w[bundle config set --local path vendor/bundle], chdir: @app.app_path
    run! %w[bundle config set --local without development:test], chdir: @app.app_path
    # Auto-remove gems not in the lock after every install. Without this, a stale
    # copy of a default gem (e.g. an older stringio left in vendor/bundle) survives
    # a re-bundle and Passenger pre-activates the wrong version — the app boots for
    # the warm process but dies on the next cold spawn, so verify! misses it.
    run! %w[bundle config set --local clean true], chdir: @app.app_path
    run! %w[bundle install --jobs 4], chdir: @app.app_path
  end

  def prepare_databases!
    log "\n--- prepare databases ---\n"
    run! %w[bundle exec rails db:prepare], chdir: @app.app_path
  end

  def precompile_assets!
    log "\n--- assets:precompile ---\n"
    run! %w[bundle exec rails assets:precompile], chdir: @app.app_path
  end

  def restart!
    log "\n--- restart Passenger ---\n"
    tmp = File.join(@app.app_path, "tmp")
    FileUtils.mkdir_p(tmp)
    FileUtils.touch(File.join(tmp, "restart.txt"))
    log "touched tmp/restart.txt\n"
  end

  def destroy!
    log "\n--- remove Plesk subdomain ---\n"
    plesk "remove subdomain", Plesk.remove_subdomain(@app.subdomain, @app.domain)
  end

  def verify!
    log "\n--- verify live site ---\n"
    result = health_check.call
    return if result.healthy?

    raise StepFailed, "site not healthy after deploy (#{result.status}: #{result.reason})"
  end

  def health_check
    @health_check ||= DeployHealthCheck.new(@app, logger: ->(message) { log message })
  end

  # ---- manager self-deploy -------------------------------------------------

  # True when the app being deployed is the manager itself — its checkout is the
  # very tree this runner boots from. `start_with?` rather than equality because
  # under the atomic strategy Rails.root is app_path/current/… , not app_path.
  def manager_self_deploy?
    root = File.expand_path(@app.app_path)
    here = File.expand_path(Rails.root.to_s)
    here == root || here.start_with?("#{root}/")
  end

  # Restart the Solid Queue service via the privileged wrapper. Touching
  # tmp/restart.txt reloads the Passenger *web* process, but the Solid Queue
  # worker (where this job runs) is a separate long-lived process still holding
  # the OLD code. The wrapper uses `systemctl restart --no-block`, so this
  # returns at once and Solid Queue can finish this job and shut down gracefully
  # before systemd swaps in a worker on the new code — no self-inflicted
  # SIGKILL, and the job isn't re-run. Non-fatal: the deploy already verified
  # healthy, so a reload hiccup is a warning (fall back to a manual
  # `systemctl restart ltvb-apps-jobs`).
  def restart_jobs_worker!
    log "\n--- restart jobs worker (manager self-deploy) ---\n"
    res = @privileged.run("restart-jobs")
    if res.ok
      log "queued ltvb-apps-jobs restart — the new worker will load the deployed code\n"
    else
      log "WARN: could not restart jobs worker (#{res.err.presence || 'failed'}); " \
          "run `systemctl restart ltvb-apps-jobs` manually\n"
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

  # Every command a deploy runs must run as the app's OWN webspace user: five of
  # the six subscriptions on this box are not `ltvb`, and a build done as the
  # wrong uid leaves a tree that webspace's own FPM pool and cron jobs cannot
  # rewrite. The manager cannot become another user unaided — its sudoers rule
  # grants exactly one program, and the agent deliberately exposes no "run this
  # as user X" verb because that verb is a root shell with extra steps. So prove
  # `sudo -u` is permitted BEFORE anything is written, and name the grant that is
  # missing instead of building the whole tree as the wrong user first.
  def ensure_deploy_user!
    return if @shell.can_become_user?

    raise StepFailed,
          "#{@app.name} must be built as #{@app.deploy_user}, but #{Shell.current_user} cannot " \
          "become that user. Granting it is an operator decision: `#{Shell.current_user} " \
          "ALL=(#{@app.deploy_user}) NOPASSWD: ALL` in /etc/sudoers.d/, or move the app to a " \
          "webspace this manager owns."
  end

  # Child env (see AppShellEnv). Build-phase rails tasks (db:*,
  # assets:precompile) just need the app to boot, not a real secret. Apps that
  # read RAILS_MASTER_KEY from Apache (e.g. login) have no key in this shell,
  # so dummy_secret uses a throwaway one here. The real key is only used by
  # the serving process.
  def child_env(extra = {})
    return AppShellEnv.repo(extra) if @app.repo?
    return AppShellEnv.rails(@app, extra, dummy_secret: true) if @app.ruby?

    # PHP kinds have no rbenv. They do need their own webspace as HOME so
    # composer's cache and auth.json resolve to the right place.
    AppShellEnv.repo({ "HOME" => @app.webspace_root }.merge(extra))
  end

  def run!(argv, chdir:, env: {})
    log "\n$ #{argv.join(' ')}\n"
    raise StepFailed, argv.first(3).join(" ") unless @shell.run(argv, env: child_env(env), chdir: chdir)
  end

  # One recipe step. A privileged step is a verb for the vetted root wrapper, not
  # a command run as the app user — see DeployRecipes::Step.
  def run_step!(step, chdir:)
    log "\n--- #{step.label} ---\n"
    return run_privileged_step!(step) if step.privileged?

    log "$ #{step}\n"
    raise StepFailed, step.label unless @shell.run(step.argv, env: child_env(step.env_or_empty), chdir: chdir)
  end

  def run_privileged_step!(step)
    result = @privileged.run(*step.argv)
    log(result.output + "\n") if result.output.present?
    raise StepFailed, "#{step.label}: #{result.err.presence || 'failed'}" unless result.ok
  end

  def capture(*argv)
    @shell.capture(argv, env: child_env, chdir: @app.app_path)
  end

  def plesk(label, result)
    @deployment.append_log(result.output + "\n") if result.output.present?
    raise StepFailed, "#{label}: #{result.err.presence || 'failed'}" unless result.ok

    log "✓ #{label}\n"
  end

  def log(msg)
    @deployment.append_log(msg)
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Every child process a deploy starts goes through this one object. That buys
  # two things: "run it as the app's own user" is decided in exactly one place
  # rather than at thirty call sites, and a test can watch the whole command
  # sequence a deploy would run without forking any of it.
  class Shell
    Result = Struct.new(:ok, :out, :err)

    class << self
      # The user this process runs as. It cannot change under a running process,
      # so resolve it once.
      def current_user
        @current_user ||= Etc.getpwuid(Process.uid).name
      rescue ArgumentError
        @current_user = Process.uid.to_s
      end
    end

    def initialize(user: nil, on_output: nil)
      @user      = user.presence || self.class.current_user
      @on_output = on_output || ->(_line) { }
    end

    attr_reader :user

    def same_user? = user == self.class.current_user

    # Probe rather than assume. `sudo -n` never prompts, so this either returns
    # true immediately or fails immediately, and it costs one fork per deploy.
    def can_become_user?
      return true if same_user?

      system("sudo", "-n", "-u", user, "-H", "--", "true", out: File::NULL, err: File::NULL) || false
    end

    # Streams combined stdout/stderr line by line into on_output. Returns whether
    # the command succeeded; what a failure means is the caller's business.
    def run(argv, env: {}, chdir: nil)
      Bundler.with_unbundled_env do
        Open3.popen2e(spawn_env(env), *as_user(argv, env), **spawn_options(chdir)) do |stdin, out, wait|
          stdin.close
          out.each_line { |line| @on_output.call(line) }
          wait.value.success?
        end
      end
    rescue Errno::ENOENT => e
      @on_output.call("command not found: #{e.message}\n")
      false
    end

    def capture(argv, env: {}, chdir: nil)
      out, err, status = Bundler.with_unbundled_env do
        Open3.capture3(spawn_env(env), *as_user(argv, env), **spawn_options(chdir))
      end
      Result.new(!!status&.success?, out, err)
    rescue StandardError => e
      Result.new(false, "", "#{e.class}: #{e.message}")
    end

    private

    # WHY the environment is handled twice over. Within one uid, Process.spawn's
    # env hash is exact: a nil value UNSETS a variable, which is how AppShellEnv
    # strips the manager's own bundler context from the child. Across uids `sudo`
    # throws that whole environment away (env_reset) before the child sees it, so
    # the values have to be re-applied on the far side by `env` — and there the
    # unsets come free, because sudo has already dropped everything. Doing both
    # here means no caller has to know which case it is in.
    def as_user(argv, env)
      return argv if same_user?

      [ "sudo", "-n", "-u", user, "-H", "--", "env", *env.compact.map { |k, v| "#{k}=#{v}" }, *argv ]
    end

    def spawn_env(env)
      same_user? ? env : {}
    end

    # with_unbundled_env plus this hash is what keeps the MANAGER's bundler out
    # of the child: unsetenv_others must stay false (the child still needs PATH,
    # HOME and the rest), so the unsetting is done by AppShellEnv's nils.
    def spawn_options(chdir)
      options = { unsetenv_others: false }
      options[:chdir] = chdir if chdir
      options
    end
  end
end
