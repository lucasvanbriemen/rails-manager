require "net/http"

# Does the app answer? Asked after a deploy has moved code, and again after a
# rollback has moved it back.
#
# WHY this is a separate object from AppStatusChecker, which also probes a URL:
# the two answer different questions and must be allowed to disagree. The
# dashboard's question is "is this site alive", so an API app whose "/" honestly
# 404s is up and a page rendered by Rails is up whatever its status code. The
# deploy gate's question is "did the code I just promoted work", and there the
# only safe answer is a response the app is *supposed* to give: 2xx, or the 3xx
# an SSO bounce produces. A 404 or a 500 means the release serves something its
# author did not intend, which is exactly what a rollback is for. An app with no
# root route says so by pointing health_check_path at /up.
#
#   DeployHealthCheck.new(app).call     # polls, returns the last Result
#   DeployHealthCheck.new(app).probe    # exactly one request
class DeployHealthCheck
  # A release is promoted only on these. Everything else rolls back.
  HEALTHY = %i[healthy redirect].freeze

  # ReleaseLayout::Promotion decides with AppStatusChecker::HEALTHY, which
  # spells "the application answered" :rails — a name from when this manager
  # served nothing else. Translate at that one boundary (#to_h) rather than
  # calling a Laravel site's 200 a Rails response everywhere in this object.
  PROMOTION_STATUS = { healthy: :rails }.freeze

  # Plesk seeds a new docroot with this page and Apache serves it happily, so a
  # release whose app server never came up answers 200 with somebody else's
  # HTML. It is the original failure this manager was built to catch, and it is
  # indistinguishable from success by status code alone.
  PLACEHOLDER = "Domain Default page".freeze

  # An app server cold-spawns on the first request after a restart (Passenger)
  # or takes a moment to bind its socket (puma, php-fpm), so a single probe
  # would fail every healthy deploy. Bounded, because the other end of "keep
  # trying" is a deploy job that never finishes and a lock nobody can take.
  DEFAULT_TRIES   = 6
  DEFAULT_DELAY   = 2
  DEFAULT_TIMEOUT = 5

  # status:  :healthy | :redirect | :placeholder | :error | :down
  # code:    the HTTP status, or nil when nothing answered
  # reason:  one line, written for whoever is reading a failed deploy log
  Result = Struct.new(:status, :code, :reason, :attempts, keyword_init: true) do
    def healthy? = HEALTHY.include?(status)

    # The distinction the runner acts on: something served this, versus nothing
    # was listening. The first is a bad release; the second is just as often a
    # vhost that was never reloaded, and the log has to let those be told apart.
    def answered? = !code.nil?
    def down?     = status == :down

    def to_h = { status: PROMOTION_STATUS.fetch(status, status), code: code, detail: reason }
  end

  def initialize(app, tries: DEFAULT_TRIES, delay: DEFAULT_DELAY, timeout: DEFAULT_TIMEOUT,
                 sleeper: nil, http: nil, logger: nil)
    @app     = app
    @tries   = [ tries.to_i, 1 ].max
    @delay   = delay
    @timeout = timeout
    @sleeper = sleeper || ->(seconds) { sleep seconds }
    # Each attempt is announced as it happens rather than summarised at the end:
    # a deploy log that goes silent for twelve seconds looks hung.
    @logger  = logger
    # ->(uri) { Net::HTTPResponse }. Injected by tests; production never passes it.
    @http    = http
  end

  # The polling policy is readable because ReleaseLayout::Promotion runs its own
  # loop around #probe and has to borrow this one. Two objects with two
  # independent ideas of "how long do we wait for a restart" would multiply into
  # minutes and disagree about when a deploy has failed.
  attr_reader :app, :tries, :delay, :sleeper

  def url = app.health_check_url

  # Poll until healthy or out of attempts. Returns the LAST result, so a caller
  # that fails reports why the final attempt failed rather than the first.
  def call
    result = nil

    tries.times do |attempt|
      result = probe
      result.attempts = attempt + 1
      @logger&.call("  health #{attempt + 1}/#{tries}: #{result.status} — #{result.reason}\n")
      return result if result.healthy?

      # No sleep after the last attempt — that delay is time added to every
      # failed deploy and buys nothing.
      @sleeper.call(@delay) unless attempt == tries - 1
    end

    result
  end

  # Exactly one request. This is what ReleaseLayout::Promotion wants: it owns
  # its own retry loop, and two nested ones would multiply into minutes.
  def probe
    classify(fetch(URI(url)))
  rescue StandardError => e
    # Refused connection, DNS, TLS, timeout, a malformed URL — for a deploy gate
    # these are one fact: nothing answered. The class stays in the reason
    # because "Connection refused" and "no such host" send an operator to very
    # different places.
    Result.new(status: :down, code: nil, attempts: 1,
               reason: "nothing answered at #{url} (#{e.class}: #{e.message})")
  end

  private

  def classify(response)
    code = response.code.to_i

    case code
    when 200..299 then ok_or_placeholder(response, code)
    when 300..399
      Result.new(status: :redirect, code: code, attempts: 1,
                 reason: "HTTP #{code} -> #{response['location']}")
    else
      Result.new(status: :error, code: code, attempts: 1,
                 reason: "#{url} answered HTTP #{code} — the server is up but this release " \
                         "is not serving it correctly")
    end
  end

  def ok_or_placeholder(response, code)
    if placeholder?(response)
      return Result.new(status: :placeholder, code: code, attempts: 1,
                        reason: "#{url} served the Plesk default page — the app server is not " \
                                "running this release, the web server is serving its directory")
    end

    Result.new(status: :healthy, code: code, attempts: 1, reason: "HTTP #{code} from #{url}")
  end

  # Only the body is reliable: Plesk stamps `x-powered-by: PleskLin` on every
  # response, healthy apps included, so that header proves nothing.
  def placeholder?(response)
    response.body.to_s.include?(PLACEHOLDER)
  end

  def fetch(uri)
    return @http.call(uri) if @http

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl     = uri.scheme == "https"
    http.open_timeout = @timeout
    http.read_timeout = @timeout
    # A server-side probe of our own hostname. A brand new subdomain is on a
    # self-signed certificate until Let's Encrypt issues one, and refusing to
    # deploy over that would make the first deploy of every site impossible.
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    # Deliberately not following the redirect: a 3xx already answers the
    # question, and following it can walk off this host entirely.
    http.get(uri.request_uri.presence || "/")
  end
end
