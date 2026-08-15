require "test_helper"
require "tmpdir"

class ReleaseLayoutTest < ActiveSupport::TestCase
  def app(**overrides)
    App.new({
      name: "Git", app_kind: "rails", subdomain: "git", domain: "ltvb.nl",
      ruby_version: "3.3.8", git_repo_url: "git@github.com:x/y.git",
      primary_db_kind: "sqlite", doc_root_suffix: "public"
    }.merge(overrides))
  end

  def layout(**overrides)
    ReleaseLayout.new(app(**overrides), now: Time.utc(2026, 8, 15, 14, 30, 0))
  end

  # A layout rooted in a real temp directory, so the filesystem operations are
  # exercised for real rather than stubbed.
  def tmp_layout(dir, **overrides)
    a = app(**overrides)
    a.define_singleton_method(:app_path) { dir }
    ReleaseLayout.new(a, now: Time.utc(2026, 8, 15, 14, 30, 0))
  end

  # --- path arithmetic ------------------------------------------------------

  test "the layout hangs off the app path" do
    l = layout
    assert_equal "/var/www/vhosts/ltvb.nl/git.ltvb.nl", l.root
    assert_equal "/var/www/vhosts/ltvb.nl/git.ltvb.nl/releases", l.releases_path
    assert_equal "/var/www/vhosts/ltvb.nl/git.ltvb.nl/shared", l.shared_path
    assert_equal "/var/www/vhosts/ltvb.nl/git.ltvb.nl/current", l.current_path
  end

  test "release names are UTC, second-resolution and lexically sortable" do
    l = layout
    assert_equal "20260815143000", l.release_name
    assert_equal "#{l.releases_path}/20260815143000", l.new_release_path

    names = [ Time.utc(2026, 8, 15, 9, 0, 0), Time.utc(2026, 8, 15, 14, 30, 0), Time.utc(2026, 9, 1, 0, 0, 0) ]
              .map { |t| l.release_name(t) }
    assert_equal names.sort, names, "directory order must match deploy order"
  end

  # A release name built from local time would go BACKWARDS across the October
  # DST change and sort the newer release first.
  test "release names ignore the local timezone" do
    l = ReleaseLayout.new(app, now: Time.new(2026, 8, 15, 16, 30, 0, "+02:00"))
    assert_equal "20260815143000", l.release_name
  end

  # The vhost points at `current`, never at a release: the config is written once
  # and the symlink swap is what changes the served code.
  test "the document root goes through current and honours the docroot suffix" do
    assert_equal "/var/www/vhosts/ltvb.nl/git.ltvb.nl/current/public", layout.document_root
    assert_equal "/var/www/vhosts/ltvb.nl/git.ltvb.nl/current",
                 layout(app_kind: "static", doc_root_suffix: "", ruby_version: nil).document_root
  end

  test "repos keep their flat checkout" do
    assert ReleaseLayout.applies_to?(app)
    assert_not ReleaseLayout.applies_to?(app(app_kind: "repo", deploy_path: "/srv/ui"))
  end

  # --- shared state ---------------------------------------------------------

  test "rails shares its logs, sqlite storage, uploads and secrets" do
    l = layout
    assert_equal [ "log", "storage", "public/uploads" ], l.shared_dirs
    assert_equal [ ".env", "config/master.key" ], l.shared_files
  end

  # A plain PHP site serves from its own root, so uploads are not under public/.
  test "the shared uploads directory follows the document root suffix" do
    assert_equal "public/uploads", layout.uploads_dir
    assert_equal "uploads", layout(app_kind: "php", doc_root_suffix: "", ruby_version: nil, php_version: "8.3").uploads_dir
  end

  test "a static site shares nothing" do
    l = layout(app_kind: "static", doc_root_suffix: "", ruby_version: nil)
    assert_empty l.shared_dirs
    assert_empty l.shared_files
    assert_empty l.seeded_dirs
  end

  test "links point out of the release into shared" do
    l = layout
    link = l.links("#{l.releases_path}/20260815143000").find { |k| k.link.end_with?("config/master.key") }

    assert_equal "#{l.shared_path}/config/master.key", link.target
    assert_not link.dir?
    assert l.links("#{l.releases_path}/20260815143000").find { |k| k.link.end_with?("/storage") }.dir?
  end

  # Build caches are per-release, not symlinked: `bundle install` for the NEXT
  # release must not delete gems out from under the release serving traffic.
  test "build caches are seeded per release rather than shared by symlink" do
    l = layout
    assert_equal [ "vendor/bundle", "node_modules" ], l.seeded_dirs
    assert_empty l.shared_dirs & l.seeded_dirs

    seed = l.seeds("#{l.releases_path}/20260815143000").first
    assert_equal "#{l.shared_path}/vendor/bundle", seed.source
    assert_equal "#{l.releases_path}/20260815143000/vendor/bundle", seed.dest
  end

  # A symlink into a directory that does not exist is a dangling link, and the
  # app boots far enough to fail confusingly.
  test "the shared skeleton includes the parent of every shared file" do
    assert_includes layout.shared_skeleton, "/var/www/vhosts/ltvb.nl/git.ltvb.nl/shared/config"
  end

  # --- the atomic swap ------------------------------------------------------

  test "swap points current at the release and leaves no staging link behind" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      target = File.join(dir, "releases", "20260815143000")
      FileUtils.mkdir_p(target)

      l.swap!(target)

      assert_equal target, l.current_target
      assert_not File.symlink?(l.staged_current_path)
    end
  end

  # File.symlink alone raises EEXIST over an existing `current`; the rename is
  # what makes replacing it possible AND atomic.
  test "swap replaces an existing current symlink" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      a = File.join(dir, "releases", "a")
      b = File.join(dir, "releases", "b")
      FileUtils.mkdir_p(a)
      FileUtils.mkdir_p(b)

      l.swap!(a)
      l.swap!(b)

      assert_equal b, l.current_target
    end
  end

  # THE atomicity contract, stated deterministically and in two halves.
  #
  # 1. Staging the replacement must not disturb `current`. `ln -sfn` gets this
  #    wrong: it unlinks `current` and only then creates the new link.
  # 2. The entry that ends up at `current` must BE the link that was staged.
  #    rename(2) moves that inode into place; an unlink-then-symlink cannot —
  #    it would leave a brand new inode, which is the same statement as "the
  #    entry was missing in between". Inode identity is the signature of the
  #    atomic path, and it holds without mocking a syscall.
  test "current is replaced by renaming the staged link, never re-created" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      a, b = two_releases(dir)
      l.swap!(a)
      before = File.lstat(l.current_path).ino

      staged = File.lstat(l.stage_current!(b)).ino
      assert_equal a, l.current_target, "current must not move until the rename"
      assert_equal before, File.lstat(l.current_path).ino
      assert_equal b, File.readlink(l.staged_current_path)
      assert_not_equal before, staged

      l.commit_current!

      assert_equal b, l.current_target
      assert_equal staged, File.lstat(l.current_path).ino, "current was re-created instead of renamed over"
      assert_not File.symlink?(l.staged_current_path), "the rename consumes the staged name"
    end
  end

  # The same contract observed the way a web server observes it: lstat the
  # DocumentRoot entry while deploys hammer past. rename(2) replaces the entry in
  # one step, so it is never missing. (The naive unlink-then-symlink loses the
  # entry thousands of times over this many iterations.)
  test "the current entry never disappears while releases are being swapped" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      a, b = two_releases(dir)
      l.swap!(a)

      misses = 0
      done   = false
      reader = Thread.new do
        until done
          misses += 1 unless File.symlink?(l.current_path)
        end
      end

      2000.times { |i| l.swap!(i.even? ? b : a) }
      done = true
      reader.join

      assert_equal 0, misses, "current vanished mid-swap — the swap is not a rename(2)"
    end
  end

  # A swap that cannot complete must leave the previous state untouched and take
  # its staging link with it. `current` is a real directory here, which is the
  # pre-migration flat layout: renaming a symlink over a directory fails.
  test "a failed swap changes nothing and cleans up after itself" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      _a, b = two_releases(dir)
      FileUtils.mkdir_p(l.current_path)
      File.write(File.join(l.current_path, "index.html"), "live")

      assert_raises(SystemCallError) { l.swap!(b) }

      assert_equal "live", File.read(File.join(l.current_path, "index.html"))
      assert_not File.symlink?(l.staged_current_path), "staging link must be cleaned up"
    end
  end

  test "the staging link lives beside current so rename stays on one filesystem" do
    l = layout
    assert_equal File.dirname(l.current_path), File.dirname(l.staged_current_path)
  end

  test "current_target is nil before the first deploy" do
    Dir.mktmpdir { |dir| assert_nil tmp_layout(dir).current_target }
  end

  # --- pruning safety -------------------------------------------------------

  test "removing a release deletes only direct children of releases" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      doomed = File.join(dir, "releases", "20260815120000")
      FileUtils.mkdir_p(doomed)

      assert_equal doomed, l.remove_release!(doomed)
      assert_not Dir.exist?(doomed)
    end
  end

  # `rm -rf` under a webspace root is the most dangerous thing this manager does.
  test "removing a release refuses anything outside the releases directory" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      [ dir, File.join(dir, "shared"), File.join(dir, "releases"),
        File.join(dir, "releases", "..", "shared"),
        File.join(dir, "releases", "a", "b"), "/var/www/vhosts" ].each do |path|
        assert_raises(ReleaseLayout::UnsafePath, "should refuse #{path}") { l.remove_release!(path) }
      end
    end
  end

  test "removing a release refuses the release that is currently live" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      live = File.join(dir, "releases", "20260815143000")
      FileUtils.mkdir_p(live)
      l.swap!(live)

      assert_raises(ReleaseLayout::UnsafePath) { l.remove_release!(live) }
      assert Dir.exist?(live)
    end
  end

  test "release names on disk are listed newest first and empty when there are none" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      assert_empty l.release_names

      %w[20260815120000 20260815143000 20260814090000].each { |n| FileUtils.mkdir_p(l.release_path(n)) }
      assert_equal %w[20260815143000 20260815120000 20260814090000], l.release_names
    end
  end

  # --- deploy lock ----------------------------------------------------------

  test "a second deploy of the same app is refused while the first holds the lock" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      inner_ran = false

      l.with_deploy_lock do
        assert_raises(ReleaseLayout::Locked) { l.with_deploy_lock { inner_ran = true } }
      end

      assert_not inner_ran
    end
  end

  test "the lock is released when the block finishes, even on failure" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      assert_raises(RuntimeError) { l.with_deploy_lock { raise "boom" } }

      ran = false
      l.with_deploy_lock { ran = true }
      assert ran
    end
  end

  test "the lock file records who holds it" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      l.with_deploy_lock { assert_match(/\A#{Process.pid} /, File.read(l.lock_path)) }
    end
  end

  # --- promotion + rollback -------------------------------------------------

  RAILS_OK   = { status: :rails, code: 200, detail: "/up healthy" }.freeze
  BROKEN     = { status: :error5xx, code: 500, detail: "server error" }.freeze

  def promotion(l, release:, previous: nil, health:, **opts)
    ReleaseLayout::Promotion.new(
      layout: l, release_path: release, previous_path: previous,
      health: health, restart: opts.delete(:restart) || -> { },
      tries: 2, delay: 0, sleeper: ->(_) { }, **opts
    )
  end

  def two_releases(dir)
    a = File.join(dir, "releases", "a")
    b = File.join(dir, "releases", "b")
    FileUtils.mkdir_p(a)
    FileUtils.mkdir_p(b)
    [ a, b ]
  end

  test "a healthy promotion swaps once and restarts once" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      a, b = two_releases(dir)
      l.swap!(a)
      restarts = 0

      result = promotion(l, release: b, previous: a, health: -> { RAILS_OK },
                         restart: -> { restarts += 1 }).call

      assert result.ok?
      assert_not result.rolled_back?
      assert_equal b, l.current_target
      assert_equal 1, restarts
    end
  end

  test "an unhealthy promotion puts the previous release back and restarts again" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      a, b = two_releases(dir)
      l.swap!(a)
      restarts = 0
      # Broken while b is live; healthy again once a is back.
      health = -> { l.current_target == b ? BROKEN : RAILS_OK }

      result = promotion(l, release: b, previous: a, health: health,
                         restart: -> { restarts += 1 }).call

      assert_not result.ok?
      assert result.rolled_back?
      assert_equal a, l.current_target, "the previous release must be serving again"
      assert_equal 2, restarts
      assert_match(/rolled back/, result.detail)
    end
  end

  # First deploy: there is nothing to fall back to. Leaving `current` on the
  # broken release beats deleting it — the operator gets a directory to inspect
  # instead of a missing DocumentRoot.
  test "a first deploy that fails health is reported without a rollback" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      _a, b = two_releases(dir)

      result = promotion(l, release: b, previous: nil, health: -> { BROKEN }).call

      assert_not result.ok?
      assert_not result.rolled_back?
      assert_equal b, l.current_target
      assert_match(/no previous release/, result.detail)
    end
  end

  test "a rollback that is also unhealthy says so instead of claiming success" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      a, b = two_releases(dir)
      l.swap!(a)

      result = promotion(l, release: b, previous: a, health: -> { BROKEN }).call

      assert_not result.ok?
      assert result.rolled_back?
      assert_match(/ALSO unhealthy/, result.detail)
    end
  end

  # A restarted app server cold-spawns on the first request, so a single probe
  # would fail every healthy deploy.
  test "the health check is retried before giving up" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      _a, b = two_releases(dir)
      calls = 0
      health = -> { calls += 1; calls < 3 ? BROKEN : RAILS_OK }

      result = ReleaseLayout::Promotion.new(
        layout: l, release_path: b, health: health, restart: -> { },
        tries: 4, delay: 7, sleeper: ->(_) { }
      ).call

      assert result.ok?
      assert_equal 3, calls
    end
  end

  test "a redirect counts as healthy, matching the status checker" do
    Dir.mktmpdir do |dir|
      l = tmp_layout(dir)
      _a, b = two_releases(dir)
      redirect = { status: :redirect, code: 302, detail: "→ https://login.ltvb.nl/" }

      assert promotion(l, release: b, health: -> { redirect }).call.ok?
    end
  end
end
