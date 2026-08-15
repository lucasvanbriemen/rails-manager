require "test_helper"
require "tmpdir"

class DeployRunnerTest < ActiveSupport::TestCase
  # Fixed so a release name is predictable: releases/20260815143000.
  NOW          = Time.utc(2026, 8, 15, 14, 30, 0)
  RELEASE_NAME = "20260815143000".freeze
  SHA          = "0f1e2d3c4b5a69788796a5b4c3d2e1f001122334".freeze

  HEALTHY = DeployHealthCheck::Result.new(status: :healthy, code: 200, reason: "HTTP 200")
  BROKEN  = DeployHealthCheck::Result.new(status: :error, code: 500, reason: "HTTP 500")

  Command = Struct.new(:argv, :env, :chdir)

  # Stands in for DeployRunner::Shell. Records every command a deploy would run
  # instead of forking it, and reproduces only the side effects the runner
  # actually depends on: a mirror appearing, a ref resolving, a tarball landing
  # in the release directory.
  class FakeShell
    attr_reader :commands
    attr_accessor :become_user

    def initialize(fail_on: [], sha: SHA, files: { "Gemfile" => "source \"https://rubygems.org\"\n" })
      @commands    = []
      @fail_on     = Array(fail_on)
      @sha         = sha
      @files       = files
      @become_user = true
    end

    def same_user?       = true
    def can_become_user? = @become_user

    def run(argv, env: {}, chdir: nil)
      @commands << Command.new(argv, env, chdir)
      return false if failing?(argv)

      simulate(argv)
      true
    end

    def capture(argv, env: {}, chdir: nil)
      @commands << Command.new(argv, env, chdir)
      return DeployRunner::Shell::Result.new(false, "", "no such ref") if failing?(argv)

      DeployRunner::Shell::Result.new(true, argv.include?("rev-parse") ? "#{@sha}\n" : "", "")
    end

    # Any command whose line contains one of the fragments fails.
    def failing?(argv) = @fail_on.any? { |fragment| argv.join(" ").include?(fragment) }

    def ran?(*fragment)
      @commands.any? { |command| command.argv.each_cons(fragment.size).any? { |slice| slice == fragment } }
    end

    def find(*fragment)
      @commands.find { |command| command.argv.each_cons(fragment.size).any? { |slice| slice == fragment } }
    end

    private

    def simulate(argv)
      case argv.first
      when "git" then FileUtils.mkdir_p(File.join(argv.last, "objects")) if argv.include?("clone")
      when "tar" then extract(argv.last)
      end
    end

    def extract(into)
      @files.each do |name, contents|
        path = File.join(into, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
      end
    end
  end

  # DeployHealthCheck's interface: one probe, plus the polling policy that
  # ReleaseLayout::Promotion borrows.
  class FakeHealth
    attr_reader :probes, :tries, :delay, :sleeper

    def initialize(tries: 2, &answer)
      @answer  = answer
      @probes  = 0
      @tries   = tries
      @delay   = 0
      @sleeper = ->(_seconds) { }
    end

    def probe
      @probes += 1
      @answer.call
    end
    alias_method :call, :probe
  end

  class FakePrivileged
    attr_reader :calls

    # The block sees each verb as it is invoked, which is how a test asserts
    # WHEN a restart happened rather than only that it did.
    def initialize(ok: true, &observer)
      @calls    = []
      @ok       = ok
      @observer = observer
    end

    def run(verb, *args)
      @calls << [ verb.to_s, *args.map(&:to_s) ]
      @observer&.call(verb.to_s)
      PrivilegedShell::Result.new(@ok, "", @ok ? "" : "unknown verb")
    end
  end

  # --- setup ----------------------------------------------------------------

  def make_app(dir, **overrides)
    record = App.create!({ name: "Git", app_kind: "rails", subdomain: "git", domain: "ltvb.nl",
                           ruby_version: "3.3.8", git_repo_url: "git@github.com:x/y.git",
                           primary_db_kind: "sqlite", doc_root_suffix: "public" }.merge(overrides))
    # Both point out of /var/www/vhosts and into the temp directory, so the
    # filesystem half of a deploy runs for real.
    record.define_singleton_method(:app_path)   { dir }
    record.define_singleton_method(:rbenv_root) { File.join(dir, ".rbenv") }
    record
  end

  def atomic_app(dir, **overrides) = make_app(dir, deploy_strategy: DeployRunner::ATOMIC, **overrides)

  def healthy = FakeHealth.new { HEALTHY }
  def broken  = FakeHealth.new { BROKEN }

  def layout_for(app) = ReleaseLayout.new(app, now: NOW)

  def run_deploy(app, shell:, health: nil, privileged: nil, ref: nil, kind: "deploy")
    deployment = Deployment.create!(app: app, kind: kind)
    ok = DeployRunner.new(deployment, ref: ref, shell: shell, privileged: privileged || FakePrivileged.new,
                          health_check: health || healthy, now: NOW).call
    [ ok, deployment.reload ]
  end

  # A release that is already live, so a rollback has somewhere to go.
  def seed_previous_release!(app, layout, name: "20260814090000")
    path = layout.release_path(name)
    FileUtils.mkdir_p(path)
    layout.swap!(path)
    app.releases.create!(path: path, status: Release::LIVE, deployed_at: 1.day.ago)
  end

  def install_rbenv(dir, version: "3.3.8")
    FileUtils.mkdir_p(File.join(dir, ".rbenv", "versions", version))
  end

  # --- strategy -------------------------------------------------------------

  test "an app deploys in place until somebody deliberately switches it" do
    assert_equal DeployRunner::IN_PLACE, App.new.deploy_strategy
  end

  test "the strategy column only accepts a value the runner understands" do
    Dir.mktmpdir do |dir|
      app = make_app(dir, deploy_strategy: "something-else")
      deployment = Deployment.create!(app: app, kind: "deploy")

      assert_equal DeployRunner::IN_PLACE, DeployRunner.new(deployment).strategy
    end
  end

  # A repo is a flat checkout other apps mount by path; a `current` symlink under
  # it would break every consumer's include path, so the kind vetoes the setting.
  test "a repo keeps its flat checkout even when switched to atomic" do
    app = App.create!(name: "ui-components", app_kind: "repo", deploy_path: "/srv/ui-components",
                      git_repo_url: "git@github.com:x/ui.git", primary_db_kind: "sqlite",
                      deploy_strategy: DeployRunner::ATOMIC)
    deployment = Deployment.create!(app: app, kind: "deploy")

    assert_equal DeployRunner::IN_PLACE, DeployRunner.new(deployment).strategy
  end

  # --- the in-place path, unchanged ----------------------------------------

  test "the in-place path still runs today's steps" do
    Dir.mktmpdir do |dir|
      app = make_app(dir)
      install_rbenv(dir)
      shell = FakeShell.new

      ok, deployment = run_deploy(app, shell: shell)

      assert ok, deployment.log
      assert_equal "succeeded", deployment.status
      assert shell.ran?("reset", "--hard", "origin/main")
      assert shell.ran?("config", "set", "--local", "path", "vendor/bundle")
      assert shell.ran?("bundle", "install", "--jobs", "4")
      assert shell.ran?("bundle", "exec", "rails", "db:prepare")
      assert shell.ran?("bundle", "exec", "rails", "assets:precompile")
      assert File.exist?(File.join(dir, "tmp", "restart.txt"))
    end
  end

  # The defect this whole task exists to fix, stated as a test so that switching
  # an app to `atomic` is visibly a different thing: in place, every command runs
  # in the directory the web server is serving.
  test "the in-place path builds in the directory the web server serves" do
    Dir.mktmpdir do |dir|
      app = make_app(dir)
      install_rbenv(dir)
      shell = FakeShell.new

      run_deploy(app, shell: shell)

      assert_equal [ dir ], shell.commands.map(&:chdir).uniq
      assert_empty app.releases.reload
      assert_not File.exist?(File.join(dir, "current"))
    end
  end

  test "a failing step aborts an in-place deploy before it restarts anything" do
    Dir.mktmpdir do |dir|
      app = make_app(dir)
      install_rbenv(dir)
      shell = FakeShell.new(fail_on: [ "assets:precompile" ])

      ok, deployment = run_deploy(app, shell: shell)

      assert_not ok
      assert_equal "failed", deployment.status
      assert_not File.exist?(File.join(dir, "tmp", "restart.txt"))
    end
  end

  test "an in-place deploy without a healthy site fails" do
    Dir.mktmpdir do |dir|
      app = make_app(dir)
      install_rbenv(dir)

      ok, deployment = run_deploy(app, shell: FakeShell.new, health: broken)

      assert_not ok
      assert_match(/not healthy after deploy/, deployment.log)
    end
  end

  # heal_stringio! appended `gem "stringio", …` to the app's own tracked Gemfile
  # when a deploy failed its health check. A deploy that edits the repository it
  # is deploying is a trap: the next `git reset --hard` reverts the "fix"
  # silently and the change never appears in review.
  test "a failed deploy never edits the app's own Gemfile" do
    Dir.mktmpdir do |dir|
      app = make_app(dir)
      install_rbenv(dir)
      gemfile = File.join(dir, "Gemfile")
      File.write(gemfile, "source \"https://rubygems.org\"\ngem \"rails\"\n")
      before = File.read(gemfile)
      shell = FakeShell.new

      ok, _deployment = run_deploy(app, shell: shell, health: broken)

      assert_not ok
      assert_equal before, File.read(gemfile), "the deploy rewrote the repository it was deploying"
      assert_not shell.ran?("bundle", "clean", "--force")
      assert_not shell.ran?("config", "set", "--local", "frozen", "false")
    end
  end

  test "heal_stringio is gone, not merely unreachable" do
    assert_not DeployRunner.method_defined?(:heal_stringio!)
    assert_not DeployRunner.private_method_defined?(:heal_stringio!)
  end

  # --- the atomic path ------------------------------------------------------

  test "a successful atomic deploy builds a release and then makes it current" do
    Dir.mktmpdir do |dir|
      app    = atomic_app(dir)
      layout = layout_for(app)

      ok, deployment = run_deploy(app, shell: FakeShell.new)

      release = app.releases.reload.sole
      assert ok, deployment.log
      assert_equal "succeeded", deployment.status
      assert_equal layout.release_path(RELEASE_NAME), release.path
      assert_equal Release::LIVE, release.status
      assert_equal SHA, release.git_ref
      assert_equal SHA, deployment.ref
      assert File.exist?(File.join(release.path, "Gemfile")), "the release has no code in it"
    end
  end

  test "a successful atomic deploy leaves exactly one current, and it is a symlink" do
    Dir.mktmpdir do |dir|
      app    = atomic_app(dir)
      layout = layout_for(app)
      seed_previous_release!(app, layout)

      run_deploy(app, shell: FakeShell.new)

      assert_equal 1, Dir.children(dir).count { |name| name == "current" }
      assert File.symlink?(layout.current_path)
      assert_equal layout.release_path(RELEASE_NAME), layout.current_target
      assert_not File.exist?(layout.staged_current_path), "the staging link was left behind"
      assert_equal 1, app.releases.reload.where(status: Release::LIVE).count
      assert_equal 2, Dir.children(layout.releases_path).size
    end
  end

  test "the build runs in the new release, never in the directory being served" do
    Dir.mktmpdir do |dir|
      app     = atomic_app(dir)
      layout  = layout_for(app)
      release = layout.release_path(RELEASE_NAME)
      shell   = FakeShell.new

      run_deploy(app, shell: shell)

      build = shell.commands.reject { |command| %w[git tar].include?(command.argv.first) }
      assert_not_empty build
      assert_equal [ release ], build.map(&:chdir).uniq
      assert_not_includes shell.commands.map(&:chdir), layout.current_path
    end
  end

  # The zero-callers problem this task exists to fix: the recipe is now what a
  # deploy actually runs, in the recipe's order.
  test "the atomic build is the app kind's recipe, minus the steps that belong after the swap" do
    Dir.mktmpdir do |dir|
      app     = atomic_app(dir)
      release = layout_for(app).release_path(RELEASE_NAME)
      shell   = FakeShell.new

      run_deploy(app, shell: shell)

      expected = DeployRecipes.for(app, release_path: release)
                              .reject { |step| DeployRunner::PROMOTION_STEP_KEYS.include?(step.key) }
                              .map(&:argv)
      assert_equal %w[bundle bundle bundle], expected.map(&:first), "recipe changed; update this test"
      assert_equal expected, shell.commands.map(&:argv).select { |argv| expected.include?(argv) }
    end
  end

  # The per-release bundle is what makes the deleted stringio workaround
  # unnecessary: gems go inside the release, and anything not in the lock is
  # dropped rather than left for Passenger to pre-activate.
  test "every bundle command in a release carries the release-scoped bundler configuration" do
    Dir.mktmpdir do |dir|
      shell = FakeShell.new
      run_deploy(atomic_app(dir), shell: shell)

      bundles = shell.commands.select { |command| command.argv.first == "bundle" }
      assert_not_empty bundles
      bundles.each do |command|
        assert_equal "vendor/bundle", command.env["BUNDLE_PATH"], command.argv.inspect
        assert_equal "true", command.env["BUNDLE_CLEAN"], command.argv.inspect
        assert_equal "development:test", command.env["BUNDLE_WITHOUT"], command.argv.inspect
      end
    end
  end

  test "the app server is restarted only once current already points at the new release" do
    Dir.mktmpdir do |dir|
      app     = atomic_app(dir)
      layout  = layout_for(app)
      seen    = []
      privileged = FakePrivileged.new { |verb| seen << [ verb, layout.current_target ] }

      run_deploy(app, shell: FakeShell.new, privileged: privileged)

      assert_equal [ [ "restart-app", layout.release_path(RELEASE_NAME) ] ], seen
    end
  end

  test "shared state is written once and symlinked into the release" do
    Dir.mktmpdir do |dir|
      app    = atomic_app(dir, master_key: "0" * 32, env_text: "FOO=bar\n")
      layout = layout_for(app)

      run_deploy(app, shell: FakeShell.new)

      release = app.releases.reload.sole.path
      assert_equal "FOO=bar\n", File.read(File.join(layout.shared_path, ".env"))
      assert_equal "0" * 32, File.read(File.join(layout.shared_path, "config", "master.key"))
      assert_equal "600", format("%o", File.stat(File.join(layout.shared_path, "config", "master.key")).mode & 0o777)

      assert_equal File.join(layout.shared_path, ".env"), File.readlink(File.join(release, ".env"))
      assert_equal File.join(layout.shared_path, "storage"), File.readlink(File.join(release, "storage"))
      assert_equal File.join(layout.shared_path, "config", "master.key"),
                   File.readlink(File.join(release, "config", "master.key"))
    end
  end

  # --- a failed build must not reach current --------------------------------

  test "a build that fails never moves current" do
    Dir.mktmpdir do |dir|
      app      = atomic_app(dir)
      layout   = layout_for(app)
      previous = seed_previous_release!(app, layout)
      health   = healthy

      ok, deployment = run_deploy(app, shell: FakeShell.new(fail_on: [ "assets:precompile" ]), health: health)

      assert_not ok
      assert_equal "failed", deployment.status
      assert_equal previous.path, layout.current_target, "current moved despite a failed build"
      assert_equal Release::LIVE, previous.reload.status
      assert_equal Release::FAILED, app.releases.reload.find_by(path: layout.release_path(RELEASE_NAME)).status
      assert_equal 0, health.probes, "a build that never shipped must not be health-checked"
    end
  end

  test "a first atomic deploy that fails to build leaves no current at all" do
    Dir.mktmpdir do |dir|
      app    = atomic_app(dir)
      layout = layout_for(app)

      ok, _deployment = run_deploy(app, shell: FakeShell.new(fail_on: [ "bundle install" ]))

      assert_not ok
      assert_nil layout.current_target
      assert_not File.exist?(layout.current_path)
    end
  end

  # The directory is evidence, and Release.prunable retires it on a later deploy.
  test "a failed build leaves its release directory on disk to be looked at" do
    Dir.mktmpdir do |dir|
      app    = atomic_app(dir)
      layout = layout_for(app)

      run_deploy(app, shell: FakeShell.new(fail_on: [ "bundle install" ]))

      assert Dir.exist?(layout.release_path(RELEASE_NAME))
    end
  end

  test "a ref that does not exist fails before a release directory is ever promoted" do
    Dir.mktmpdir do |dir|
      app    = atomic_app(dir)
      layout = layout_for(app)

      ok, deployment = run_deploy(app, shell: FakeShell.new(fail_on: [ "rev-parse" ]), ref: "deadbeef")

      assert_not ok
      assert_match(/no such ref/, deployment.log)
      assert_nil layout.current_target
    end
  end

  # --- a failed health check must roll back ---------------------------------

  test "a release that fails its health check is swapped back off" do
    Dir.mktmpdir do |dir|
      app      = atomic_app(dir)
      layout   = layout_for(app)
      previous = seed_previous_release!(app, layout)
      fresh    = layout.release_path(RELEASE_NAME)
      # Broken while the new release is current, healthy again once the old one is.
      health   = FakeHealth.new { layout.current_target == fresh ? BROKEN : HEALTHY }

      ok, deployment = run_deploy(app, shell: FakeShell.new, health: health)

      assert_not ok
      assert_equal "failed", deployment.status
      assert_equal previous.path, layout.current_target, "the previous release must be serving again"
      assert_equal Release::ROLLED_BACK, app.releases.reload.find_by(path: fresh).status
      assert_equal Release::LIVE, previous.reload.status
      assert_match(/rolled back/, deployment.log)
    end
  end

  test "the app server is restarted again on the way back, so the rollback actually serves" do
    Dir.mktmpdir do |dir|
      app        = atomic_app(dir)
      layout     = layout_for(app)
      previous   = seed_previous_release!(app, layout)
      fresh      = layout.release_path(RELEASE_NAME)
      seen       = []
      privileged = FakePrivileged.new { seen << layout.current_target }
      health     = FakeHealth.new { layout.current_target == fresh ? BROKEN : HEALTHY }

      run_deploy(app, shell: FakeShell.new, health: health, privileged: privileged)

      assert_equal [ fresh, previous.path ], seen
    end
  end

  # Nothing to fall back to. Leaving `current` on the broken release beats
  # deleting it — the operator gets logs and a directory instead of a missing
  # DocumentRoot — and the table has to admit that is what is serving.
  test "a first deploy that fails its health check stays live and says why" do
    Dir.mktmpdir do |dir|
      app    = atomic_app(dir)
      layout = layout_for(app)

      ok, deployment = run_deploy(app, shell: FakeShell.new, health: broken)

      assert_not ok
      assert_equal layout.release_path(RELEASE_NAME), layout.current_target
      assert_equal Release::LIVE, app.releases.reload.sole.status
      assert_match(/no previous release/, deployment.log)
    end
  end

  test "a rollback that is also unhealthy is reported rather than called a success" do
    Dir.mktmpdir do |dir|
      app    = atomic_app(dir)
      layout = layout_for(app)
      seed_previous_release!(app, layout)

      ok, deployment = run_deploy(app, shell: FakeShell.new, health: broken)

      assert_not ok
      assert_match(/ALSO unhealthy/, deployment.log)
    end
  end

  # --- guards ---------------------------------------------------------------

  test "a row whose path cannot be trusted is refused before anything runs" do
    Dir.mktmpdir do |dir|
      # No subdomain and no apex confirmation: app_path would be the apex site's
      # own files, which a deploy would `git reset --hard`.
      app   = make_app(dir, subdomain: nil)
      shell = FakeShell.new

      ok, deployment = run_deploy(app, shell: shell)

      assert_not ok
      assert_match(/refusing to deploy/, deployment.log)
      assert_empty shell.commands
    end
  end

  # Five of the six webspaces on this box are not `ltvb`, and a build done as the
  # wrong uid leaves a tree that webspace's own FPM pool cannot rewrite.
  test "a deploy that cannot run as the app's own user is refused before anything is written" do
    Dir.mktmpdir do |dir|
      app   = atomic_app(dir, runtime_user: "djtim.eu_aqwzxapl85w")
      shell = FakeShell.new
      shell.become_user = false

      ok, deployment = run_deploy(app, shell: shell)

      assert_not ok
      assert_match(/must be built as djtim\.eu_aqwzxapl85w/, deployment.log)
      assert_empty shell.commands
      assert_empty Dir.children(dir)
    end
  end

  test "a command for another webspace's user is handed to sudo with its environment re-applied" do
    shell = DeployRunner::Shell.new(user: "voordezorgmanagement._rhc4zy0iyc")

    assert_not shell.same_user?
    # RUBYOPT is nil — sudo's env_reset has already dropped it, so it must not be
    # re-applied on the far side.
    assert_equal %w[sudo -n -u voordezorgmanagement._rhc4zy0iyc -H -- env BUNDLE_PATH=vendor/bundle
                    bundle install],
                 shell.send(:as_user, %w[bundle install],
                            { "BUNDLE_PATH" => "vendor/bundle", "RUBYOPT" => nil })
  end

  test "a command for this manager's own user is run directly" do
    shell = DeployRunner::Shell.new(user: DeployRunner::Shell.current_user)

    assert shell.same_user?
    assert shell.can_become_user?
    assert_equal %w[bundle install], shell.send(:as_user, %w[bundle install], { "A" => "1" })
  end

  test "a second deploy of the same app is refused while the first holds the lock" do
    Dir.mktmpdir do |dir|
      app    = atomic_app(dir)
      layout = layout_for(app)

      layout.with_deploy_lock do
        ok, deployment = run_deploy(app, shell: FakeShell.new)

        assert_not ok
        assert_match(/already running/, deployment.log)
      end
    end
  end

  # --- kinds other than rails ----------------------------------------------

  test "a static site swaps atomically with nothing to build" do
    Dir.mktmpdir do |dir|
      app    = atomic_app(dir, app_kind: "static", doc_root_suffix: "")
      layout = layout_for(app)
      shell  = FakeShell.new(files: { "index.html" => "<h1>hi</h1>" })

      ok, deployment = run_deploy(app, shell: shell)

      assert ok, deployment.log
      assert_equal layout.release_path(RELEASE_NAME), layout.current_target
      assert_not shell.ran?("bundle", "install")
      assert_equal "<h1>hi</h1>", File.read(File.join(layout.current_path, "index.html"))
    end
  end

  test "a repo pulls in place and runs its follow-up commands" do
    Dir.mktmpdir do |dir|
      app = App.create!(name: "ui-components", app_kind: "repo", deploy_path: dir,
                        git_repo_url: "git@github.com:x/ui.git", primary_db_kind: "sqlite",
                        post_deploy_commands: "npm ci\n# a comment\n./propagate.sh\n")
      shell = FakeShell.new

      ok, deployment = run_deploy(app, shell: shell)

      assert ok, deployment.log
      assert shell.ran?("bash", "-lc", "npm ci")
      assert shell.ran?("bash", "-lc", "./propagate.sh")
      assert_not File.exist?(File.join(dir, "current"))
    end
  end

  test "untracking a repo touches nothing on disk" do
    Dir.mktmpdir do |dir|
      app = App.create!(name: "ui-components", app_kind: "repo", deploy_path: dir,
                        git_repo_url: "git@github.com:x/ui.git", primary_db_kind: "sqlite")
      shell = FakeShell.new

      ok, _deployment = run_deploy(app, shell: shell, kind: "destroy")

      assert ok
      assert_empty shell.commands
      assert_empty Dir.children(dir)
    end
  end

  # --- manager self-deploy --------------------------------------------------

  def self_deploy?(path)
    Dir.mktmpdir do |dir|
      app = make_app(dir)
      app.define_singleton_method(:app_path) { path }
      DeployRunner.new(Deployment.create!(app: app, kind: "deploy")).send(:manager_self_deploy?)
    end
  end

  test "the manager recognises its own checkout" do
    assert self_deploy?(Rails.root.to_s)
  end

  # Under the atomic strategy the manager boots from app_path/current/…, so an
  # equality check would stop recognising the self-deploy and the Solid Queue
  # worker would keep running the old code forever.
  test "a checkout under the app root still counts, which is where current puts it" do
    assert self_deploy?(File.dirname(Rails.root.to_s))
  end

  test "another app's directory is not a self-deploy" do
    assert_not self_deploy?("/var/www/vhosts/ltvb.nl/git.ltvb.nl")
  end
end
