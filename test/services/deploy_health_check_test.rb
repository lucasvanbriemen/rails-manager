require "test_helper"

class DeployHealthCheckTest < ActiveSupport::TestCase
  # Enough of Net::HTTPResponse for the classifier: a status code, a body and
  # header lookup.
  Response = Struct.new(:code, :body, :headers) do
    def [](name) = (headers || {})[name]
  end

  OK          = Response.new("200", "<h1>hello</h1>")
  REDIRECT    = Response.new("302", "", { "location" => "https://login.ltvb.nl/" })
  SERVER_FIRE = Response.new("500", "we're sorry, but something went wrong")
  NOT_FOUND   = Response.new("404", "Not Found")
  PLACEHOLDER = Response.new("200", "<title>Domain Default page</title>")

  def app(**overrides)
    App.new({ name: "Git", app_kind: "rails", subdomain: "git", domain: "ltvb.nl",
              ruby_version: "3.3.8", git_repo_url: "git@github.com:x/y.git",
              primary_db_kind: "sqlite" }.merge(overrides))
  end

  # Answers with each element of `serves` in turn, repeating the last one
  # forever. An Exception element is raised instead of returned, which is how a
  # refused connection reaches the object under test.
  def check(serves, for_app: nil, **options)
    @requested = []
    @slept     = 0
    # Not Array(): a Response is a Struct, and Array() would splat it into its
    # members.
    queue      = serves.is_a?(Array) ? serves.dup : [ serves ]

    DeployHealthCheck.new(for_app || app, delay: 0, sleeper: ->(_) { @slept += 1 },
                          http: ->(uri) { @requested << uri.to_s; answer(queue) }, **options)
  end

  def answer(queue)
    value = queue.size > 1 ? queue.shift : queue.first
    raise value if value.is_a?(Exception)

    value
  end

  # --- classification -------------------------------------------------------

  test "a 2xx is healthy" do
    result = check(OK).probe

    assert result.healthy?
    assert_equal :healthy, result.status
    assert_equal 200, result.code
    assert_match(/HTTP 200/, result.reason)
  end

  # The SSO bounce to login.ltvb.nl is what most of these apps answer "/" with.
  test "a redirect is healthy and the reason says where to" do
    result = check(REDIRECT).probe

    assert result.healthy?
    assert_equal :redirect, result.status
    assert_match(%r{https://login\.ltvb\.nl/}, result.reason)
  end

  # THE distinction a rollback decision hangs on. Both are failures, but one
  # means "this release is broken" and the other means "nothing is listening on
  # that hostname at all" — usually a vhost that was never reloaded, which no
  # amount of rolling back will fix.
  test "an error response is told apart from nothing answering" do
    served = check(SERVER_FIRE).probe
    silent = check(Errno::ECONNREFUSED.new("connect(2) for 91.99.1.1:443")).probe

    assert_not served.healthy?
    assert served.answered?
    assert_not served.down?
    assert_equal 500, served.code
    assert_match(/HTTP 500/, served.reason)

    assert_not silent.healthy?
    assert_not silent.answered?
    assert silent.down?
    assert_nil silent.code
    assert_match(/nothing answered/, silent.reason)
    # The class is kept because "connection refused" and "no such host" send an
    # operator to completely different places.
    assert_match(/Errno::ECONNREFUSED/, silent.reason)
  end

  # AppStatusChecker calls a 404 served by Rails healthy, and it is right to: an
  # API app with no root route is up. A deploy gate is asking a different
  # question — "is this release serving what its author intended" — and there a
  # 404 is a failure. An app without a root route says so via health_check_path.
  test "a 404 fails the deploy gate even though the dashboard would call it up" do
    result = check(NOT_FOUND).probe

    assert_not result.healthy?
    assert_equal :error, result.status
    assert result.answered?
  end

  # 200 with somebody else's HTML: the app server never came up and the web
  # server served the directory. This is the original git.ltvb.nl failure.
  test "the Plesk placeholder is not a healthy 200" do
    result = check(PLACEHOLDER).probe

    assert_not result.healthy?
    assert_equal :placeholder, result.status
    assert_equal 200, result.code
    assert_match(/app server is not running this release/, result.reason)
  end

  test "an unexpected failure is still nothing answered rather than an exception" do
    result = check(RuntimeError.new("kaboom")).probe

    assert result.down?
    assert_match(/RuntimeError: kaboom/, result.reason)
  end

  # --- the URL --------------------------------------------------------------

  test "the app's configured health check path is what gets probed" do
    subject = check(OK, for_app: app(health_check_path: "/up"))
    subject.probe

    assert_equal [ "https://git.ltvb.nl/up" ], @requested
    assert_equal "https://git.ltvb.nl/up", subject.url
  end

  test "the default path is the site root" do
    check(OK).probe

    assert_equal [ "https://git.ltvb.nl/" ], @requested
  end

  # --- polling --------------------------------------------------------------

  # A restarted app server cold-spawns on the first request, so a single probe
  # would fail every healthy deploy.
  test "polling stops at the first healthy answer and reports how many it took" do
    subject = check([ SERVER_FIRE, SERVER_FIRE, OK ], tries: 6)

    result = subject.call

    assert result.healthy?
    assert_equal 3, result.attempts
    assert_equal 3, @requested.size
  end

  # The other end of "keep trying" is a deploy job that never finishes holding a
  # lock nobody else can take.
  test "attempts are bounded and the last result is the one reported" do
    result = check(SERVER_FIRE, tries: 4).call

    assert_not result.healthy?
    assert_equal 4, result.attempts
    assert_equal 4, @requested.size
    assert_equal 500, result.code
  end

  test "no sleep after the final attempt — that delay is added to every failed deploy" do
    check(SERVER_FIRE, tries: 4).call

    assert_equal 3, @slept
  end

  test "tries never drops below one, so a bad setting cannot skip the check entirely" do
    result = check(OK, tries: 0).call

    assert_equal 1, result.attempts
    assert result.healthy?
  end

  # ReleaseLayout::Promotion owns the retry loop around the swap, so what it
  # calls must be a single request — two nested loops multiply into minutes.
  test "a probe is exactly one request" do
    check([ SERVER_FIRE, OK ], tries: 6).probe

    assert_equal 1, @requested.size
  end

  test "each attempt is logged as it happens so a slow deploy does not look hung" do
    lines = []
    DeployHealthCheck.new(app, tries: 2, delay: 0, sleeper: ->(_) { },
                          logger: ->(line) { lines << line },
                          http: ->(_uri) { SERVER_FIRE }).call

    assert_equal 2, lines.size
    assert_match(%r{health 1/2: error}, lines.first)
  end

  # --- the contract with ReleaseLayout::Promotion ---------------------------

  # Promotion decides whether to roll back with AppStatusChecker::HEALTHY, so a
  # healthy result MUST be spelled the way that set spells it. If this fails,
  # every atomic deploy rolls back over a working release.
  test "healthy results are spelled the way Promotion tests for" do
    assert_includes AppStatusChecker::HEALTHY, check(OK).probe.to_h[:status]
    assert_includes AppStatusChecker::HEALTHY, check(REDIRECT).probe.to_h[:status]
  end

  test "unhealthy results are not accidentally spelled as healthy ones" do
    [ SERVER_FIRE, NOT_FOUND, PLACEHOLDER, Errno::ECONNREFUSED.new("refused") ].each do |served|
      status = check(served).probe.to_h[:status]
      assert_not_includes AppStatusChecker::HEALTHY, status, "#{served.inspect} must not promote"
    end
  end

  test "the hash Promotion receives carries the code and the reason" do
    hash = check(SERVER_FIRE).probe.to_h

    assert_equal 500, hash[:code]
    assert_match(/HTTP 500/, hash[:detail])
  end

  # Promotion runs its own loop around #probe and borrows this policy; two
  # objects with two ideas of how long a restart may take would disagree about
  # when a deploy has failed.
  test "the polling policy is readable so the promotion cannot invent its own" do
    subject = DeployHealthCheck.new(app, tries: 3, delay: 7)

    assert_equal 3, subject.tries
    assert_equal 7, subject.delay
    assert_respond_to subject.sleeper, :call
  end
end
