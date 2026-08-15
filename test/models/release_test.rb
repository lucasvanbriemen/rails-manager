require "test_helper"
require "tmpdir"

class ReleaseTest < ActiveSupport::TestCase
  setup do
    @app = App.create!(name: "Git", app_kind: "rails", subdomain: "git", domain: "ltvb.nl",
                       git_repo_url: "git@github.com:lucas/git.git", primary_db_kind: "sqlite")
  end

  # Release has no inverse association on App yet (App is owned elsewhere), so
  # scope through the table.
  def releases = Release.where(app_id: @app.id)

  # A second webspace, for the scoping tests: its releases live under a different
  # owner's tree and must never be offered to this app.
  def other_app
    @other_app ||= App.create!(name: "Music", app_kind: "laravel", subdomain: "music", domain: "ltvb.nl",
                               php_version: "8.3", git_repo_url: "git@github.com:lucas/music.git",
                               primary_db_kind: "external")
  end

  def build_release(name, status: Release::BUILDING, created_at: nil, path: nil)
    Release.create!(app: @app, path: path || "/var/www/vhosts/ltvb.nl/git.ltvb.nl/releases/#{name}",
                    status: status, created_at: created_at || Time.current, git_ref: "a" * 40)
  end

  # --- validations ---------------------------------------------------------

  test "a release needs a path and a known status" do
    assert_not Release.new(app: @app, path: nil).valid?
    assert_not Release.new(app: @app, path: "/x", status: "wat").valid?
  end

  test "two releases cannot claim the same directory" do
    build_release("20260815120000")
    dup = Release.new(app: @app, path: releases.first.path, status: Release::BUILDING)
    assert_not dup.valid?, "the deploy lock should prevent this; the index is the backstop"
  end

  # --- promotion bookkeeping -----------------------------------------------

  test "promoting a release supersedes the one that was live" do
    old = build_release("20260815120000", status: Release::LIVE, created_at: 2.hours.ago)
    new = build_release("20260815130000", created_at: 1.hour.ago)

    new.mark_live!
    old.reload

    assert_equal Release::SUPERSEDED, old.status
    assert_not_nil old.superseded_at
    assert_equal Release::LIVE, new.status
    assert_not_nil new.deployed_at
  end

  # A rollback marks the bad release ROLLED_BACK and then re-promotes the old
  # one. mark_live! must not relabel the failure as a clean supersede, or the
  # next deploy would happily roll back onto the release that just broke.
  test "re-promoting after a rollback leaves the failed release rolled_back" do
    good = build_release("20260815120000", status: Release::SUPERSEDED, created_at: 2.hours.ago)
    bad  = build_release("20260815130000", status: Release::LIVE, created_at: 1.hour.ago)

    bad.mark_rolled_back!
    good.mark_live!

    assert_equal Release::ROLLED_BACK, bad.reload.status
    assert_equal Release::LIVE, good.reload.status
    assert_nil good.superseded_at
  end

  test "current and previous scopes separate the live release from its history" do
    build_release("20260815110000", status: Release::SUPERSEDED, created_at: 3.hours.ago)
    rolled = build_release("20260815120000", status: Release::ROLLED_BACK, created_at: 2.hours.ago)
    live   = build_release("20260815130000", status: Release::LIVE, created_at: 1.hour.ago)
    build_release("20260815140000", status: Release::FAILED, created_at: 10.minutes.ago)

    assert_equal [ live ], releases.current.to_a
    assert_equal 2, releases.previous.count
    assert_equal rolled, releases.previous.first, "previous is newest-first"
  end

  # --- rollback target -----------------------------------------------------

  # THE regression: the fallback is chosen BEFORE the swap, so the release the
  # site must be able to return to is the one still flagged LIVE. Excluding it
  # answered with the release before that — one bad deploy rolled the site back
  # two deploys, onto code nobody had run in days.
  test "the rollback target is the release serving right now, not the one before it" do
    Dir.mktmpdir do |dir|
      build_release("n2", status: Release::SUPERSEDED, created_at: 2.hours.ago, path: File.join(dir, "n2"))
      live = build_release("n1", status: Release::LIVE, created_at: 1.hour.ago, path: File.join(dir, "n1"))
      [ "n1", "n2" ].each { |n| Dir.mkdir(File.join(dir, n)) }

      assert_equal live, Release.rollback_target(@app)
    end
  end

  # Once the swap has happened the live row is the NEW release and the code that
  # was serving is superseded — still the newest candidate, so the answer stays
  # correct either side of the promotion.
  test "the rollback target is the previous release once the new one is live" do
    Dir.mktmpdir do |dir|
      previous = build_release("n1", status: Release::SUPERSEDED, created_at: 2.hours.ago, path: File.join(dir, "n1"))
      build_release("n0", status: Release::SUPERSEDED, created_at: 3.hours.ago, path: File.join(dir, "n0"))
      [ "n0", "n1" ].each { |n| Dir.mkdir(File.join(dir, n)) }

      assert_equal previous, Release.rollback_target(@app)
    end
  end

  # Rolling back onto a release that failed to boot, or the one we just fled
  # from, would re-break the site.
  test "rollback target ignores failed and rolled_back releases" do
    Dir.mktmpdir do |dir|
      build_release("a", status: Release::FAILED, created_at: 2.hours.ago, path: File.join(dir, "a"))
      build_release("b", status: Release::ROLLED_BACK, created_at: 1.hour.ago, path: File.join(dir, "b"))
      [ "a", "b" ].each { |n| Dir.mkdir(File.join(dir, n)) }

      assert_nil Release.rollback_target(@app)
    end
  end

  # Pointing `current` at a pruned directory would take the site down harder
  # than the bad deploy that triggered the rollback.
  test "rollback target skips releases whose directory is gone" do
    Dir.mktmpdir do |dir|
      kept = build_release("a", status: Release::SUPERSEDED, created_at: 2.hours.ago, path: File.join(dir, "a"))
      build_release("b", status: Release::SUPERSEDED, created_at: 1.hour.ago, path: File.join(dir, "b"))
      Dir.mkdir(File.join(dir, "a"))

      assert_equal kept, Release.rollback_target(@app)
    end
  end

  # The answer becomes the target of a symlink swap inside ONE webspace. The
  # unscoped class method used to return the newest candidate in the whole
  # table, so a rollback of git.ltvb.nl could point its `current` at another
  # subscription's release directory — a path its uid cannot even read.
  test "rollback target never answers with another app's release" do
    Dir.mktmpdir do |dir|
      theirs = Release.create!(app: other_app, path: File.join(dir, "theirs"),
                               status: Release::SUPERSEDED, created_at: 1.minute.ago)
      mine = build_release("mine", status: Release::SUPERSEDED, created_at: 2.hours.ago,
                           path: File.join(dir, "mine"))
      [ "theirs", "mine" ].each { |n| Dir.mkdir(File.join(dir, n)) }

      assert_equal mine, Release.rollback_target(@app), "the newest candidate overall belongs to another app"
      assert_equal theirs, Release.rollback_target(other_app)
    end
  end

  # Narrowing silently would answer nil here, and a caller reads nil as "nothing
  # to roll back to" — it would leave the broken release live and say so.
  test "rollback target refuses to answer for an app it was not scoped to" do
    assert_raises(Release::CrossApp) { releases.rollback_target(other_app) }
    assert_raises(ArgumentError) { Release.rollback_target(nil) }
  end

  test "rollback target accepts either the app or its id" do
    Dir.mktmpdir do |dir|
      live = build_release("n1", status: Release::LIVE, created_at: 1.hour.ago, path: File.join(dir, "n1"))
      Dir.mkdir(File.join(dir, "n1"))

      assert_equal live, releases.rollback_target(@app)
      assert_equal live, Release.rollback_target(@app.id)
    end
  end

  # --- pruning -------------------------------------------------------------

  test "nothing is prunable while there are fewer releases than the keep count" do
    3.times { |i| build_release("r#{i}", status: Release::SUPERSEDED, created_at: (10 - i).hours.ago) }

    assert_empty releases.prunable(keep: 5)
  end

  test "prunable keeps the newest N and drops the rest" do
    made = 8.times.map { |i| build_release("r#{i}", status: Release::SUPERSEDED, created_at: (20 - i).hours.ago) }

    prunable = releases.prunable(keep: 3)
    # made is oldest-first; the three newest stay, and so does the rollback
    # target — which here IS the newest, so exactly three survive.
    assert_equal made.first(5).map(&:id).sort, prunable.map(&:id).sort
  end

  # Retention must never eat the safety net: an old known-good release stays
  # even when N newer failures have pushed it out of the keep window.
  test "prunable protects the rollback target even when it falls outside keep" do
    good = build_release("good", status: Release::SUPERSEDED, created_at: 10.hours.ago)
    4.times { |i| build_release("bad#{i}", status: Release::FAILED, created_at: (5 - i).hours.ago) }

    assert_not_includes releases.prunable(keep: 2).map(&:id), good.id
  end

  test "prunable never touches the live or the in-flight release" do
    live     = build_release("live", status: Release::LIVE, created_at: 10.hours.ago)
    building = build_release("wip",  status: Release::BUILDING, created_at: 9.hours.ago)
    5.times { |i| build_release("r#{i}", status: Release::SUPERSEDED, created_at: (5 - i).hours.ago) }

    ids = releases.prunable(keep: 1).map(&:id)
    assert_not_includes ids, live.id
    assert_not_includes ids, building.id
  end

  # --- misc ----------------------------------------------------------------

  test "record_build stores the cost of the build" do
    r = build_release("20260815120000")
    r.record_build!(duration_ms: 42_500, size_bytes: 1_234)

    assert_in_delta 42.5, r.build_duration_seconds
    assert_equal 1_234, r.reload.size_bytes
  end

  test "name is the release directory timestamp and short_ref abbreviates the sha" do
    r = build_release("20260815120000")
    assert_equal "20260815120000", r.name
    assert_equal "aaaaaaaa", r.short_ref
  end
end
