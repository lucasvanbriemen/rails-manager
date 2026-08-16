require "test_helper"
require "tmpdir"

class AppTeardownTest < ActiveSupport::TestCase
  # Stands in for Agent: records the calls and answers however the test wants,
  # so the guards can be exercised without a socket.
  class FakeAgent
    Result = Struct.new(:ok, :out, :err, :data, :code)

    attr_reader :calls

    def initialize(ok: true, err: nil)
      @ok = ok
      @err = err
      @calls = []
    end

    def call(verb, **params)
      @calls << [ verb, params ]
      Result.new(@ok, "", @err, {}, nil)
    end
  end

  setup do
    @root = Dir.mktmpdir("teardown")
    @agent = FakeAgent.new
  end

  teardown do
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  # <root>/<domain>/<dir> is the shape an app occupies on this box.
  def app_dir(domain: "ltvb.nl", name: "example.ltvb.nl")
    path = File.join(@root, domain, name)
    FileUtils.mkdir_p(File.join(path, "nested"))
    File.write(File.join(path, "nested", "file.txt"), "x")
    path
  end

  def repo_app(path)
    App.create!(name: "a repo", app_kind: "repo", deploy_path: path,
                git_repo_url: "git@github.com:x/y.git", git_branch: "main",
                ruby_version: "3.3.8", primary_db_kind: "external")
  end

  test "deletes the app's directory" do
    path = app_dir
    notes = AppTeardown.call(repo_app(path), root: @root, agent: @agent)

    assert_not File.exist?(path)
    assert_includes notes.join, "deleted #{path}"
  end

  test "refuses a webspace root — one level under the vhosts root is six subscriptions" do
    path = File.join(@root, "ltvb.nl")
    FileUtils.mkdir_p(path)

    notes = AppTeardown.call(repo_app(path), root: @root, agent: @agent)

    assert File.directory?(path), "the webspace root must survive"
    assert_includes notes.join, "is a webspace root"
  end

  test "refuses a path outside the vhosts root" do
    outside = Dir.mktmpdir("elsewhere")
    notes = AppTeardown.call(repo_app(outside), root: @root, agent: @agent)

    assert File.directory?(outside)
    assert_includes notes.join, "is outside"
  ensure
    FileUtils.remove_entry(outside) if outside && File.directory?(outside)
  end

  # "/var/www/vhosts-old/x" starts with "/var/www/vhosts" as a string and is not
  # inside it. The check is on the segment boundary for exactly this case.
  test "refuses a sibling directory whose name merely starts with the root" do
    sibling = "#{@root}-old"
    FileUtils.mkdir_p(File.join(sibling, "ltvb.nl", "app"))

    notes = AppTeardown.call(repo_app(File.join(sibling, "ltvb.nl", "app")), root: @root, agent: @agent)

    assert File.directory?(File.join(sibling, "ltvb.nl", "app"))
    assert_includes notes.join, "is outside"
  ensure
    FileUtils.remove_entry(sibling) if sibling && File.directory?(sibling)
  end

  test "refuses a symlink rather than following it" do
    real = app_dir(name: "real.ltvb.nl")
    link = File.join(@root, "ltvb.nl", "link.ltvb.nl")
    File.symlink(real, link)

    notes = AppTeardown.call(repo_app(link), root: @root, agent: @agent)

    assert File.directory?(real), "the symlink's target must survive"
    assert_includes notes.join, "is a symlink"
  end

  test "refuses a path a second app also points at" do
    path = app_dir(name: "ui-components")
    shared = repo_app(path)
    repo_app(path).update_column(:name, "another consumer")

    notes = AppTeardown.call(shared, root: @root, agent: @agent)

    assert File.directory?(path), "a shared checkout must survive"
    assert_includes notes.join, "is also"
  end

  test "refuses an apex site — its directory is the whole domain's document root" do
    path = File.join(@root, "ltvb.nl", "httpdocs")
    FileUtils.mkdir_p(path)
    apex = App.create!(name: "ltvb.nl", app_kind: "static", subdomain: "", domain: "ltvb.nl",
                       apex_confirmed: true, ruby_version: "3.3.8", primary_db_kind: "external",
                       git_repo_url: "git@github.com:x/y.git", git_branch: "main")

    notes = AppTeardown.call(apex, root: @root, agent: @agent)

    assert File.directory?(path)
    assert_includes notes.join, "apex"
  end

  test "a path that is already gone is reported, not raised" do
    notes = AppTeardown.call(repo_app(File.join(@root, "ltvb.nl", "never-existed")), root: @root, agent: @agent)

    assert_includes notes.join, "is not there any more"
  end

  # --- workers ---------------------------------------------------------------

  test "stops, disables, removes and forgets a managed worker" do
    app = repo_app(app_dir)
    app.process_services.create!(name: "example-jobs", kind: "solid_queue", user: "ltvb",
                                 working_directory: "/var/www/vhosts/ltvb.nl/example.ltvb.nl",
                                 argv: %w[/var/www/vhosts/ltvb.nl/.rbenv/shims/bundle exec rails solid_queue:start], managed: true)

    assert_difference -> { ProcessService.count }, -1 do
      AppTeardown.call(app, root: @root, agent: @agent)
    end

    verbs = @agent.calls.map(&:first)
    assert_equal %w[systemd.restart systemd.disable systemd.unit.remove], verbs
    assert_equal "stop", @agent.calls.first.last[:action]
    assert_equal "example-jobs.service", @agent.calls.first.last[:unit]
  end

  # Adopted means somebody else wrote that unit file. Stopping it is this app's
  # business; deleting a file the manager never wrote is not.
  test "stops an adopted worker but does not delete its unit file" do
    app = repo_app(app_dir)
    app.process_services.create!(name: "example-adopted", kind: "generic", user: "ltvb",
                                 working_directory: "/var/www/vhosts/ltvb.nl/example.ltvb.nl",
                                 argv: %w[/usr/bin/true], managed: false)

    notes = AppTeardown.call(app, root: @root, agent: @agent)

    assert_not_includes @agent.calls.map(&:first), "systemd.unit.remove"
    assert_includes notes.join, "not the manager's to delete"
  end

  test "a worker the agent will not stop is reported and the teardown carries on" do
    app = repo_app(path = app_dir)
    app.process_services.create!(name: "example-jobs", kind: "solid_queue", user: "ltvb",
                                 working_directory: "/var/www/vhosts/ltvb.nl/example.ltvb.nl",
                                 argv: %w[/var/www/vhosts/ltvb.nl/.rbenv/shims/bundle exec rails solid_queue:start], managed: true)

    notes = AppTeardown.call(app, root: @root, agent: FakeAgent.new(ok: false, err: "unit not found"))

    assert_includes notes.join, "could not stop example-jobs.service: unit not found"
    assert_not File.exist?(path), "the files still go"
  end
end
