require "net/http"

# Classifies what an app's URL actually serves right now. The whole point of the
# manager: catch the git.ltvb.nl failure mode (Plesk serving its default
# placeholder because Passenger never found the app) automatically — without
# false-flagging healthy apps (e.g. an API app whose "/" legitimately 404s).
module AppStatusChecker
  # Statuses considered "up": a Rails response (any code it actually handled),
  # or a redirect (e.g. the SSO bounce to login.ltvb.nl).
  HEALTHY = %i[rails redirect].freeze

  module_function

  # => { status: Symbol, code: Integer|nil, detail: String }
  def check(app)
    base = app.url # https://fqdn/

    # Prefer Rails' built-in /up health endpoint — 200 means the app booted.
    up = safe_request(URI(base + "up"))
    if up && up.code.to_i == 200 && !placeholder?(up)
      return { status: :rails, code: 200, detail: "/up healthy" }
    end

    res = safe_request(URI(base))
    return { status: :down, code: nil, detail: "no response" } unless res

    classify(res)
  end

  def safe_request(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 5
    http.read_timeout = 5
    # Server-side probe of our own hosts; new subdomains have self-signed certs
    # until Let's Encrypt issues one, so we don't verify the chain.
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.get(uri.request_uri.presence || "/")
  rescue StandardError
    nil
  end

  def classify(res)
    code = res.code.to_i

    return { status: :placeholder, code: code, detail: "Plesk default page — Passenger not serving the app" } if placeholder?(res)

    case code
    when 300..399
      { status: :redirect, code: code, detail: "→ #{res['location']}" }
    when 500..599
      { status: :error5xx, code: code, detail: "server error" }
    else
      # Any other code the app actually handled (200, 401, 404, …): if Rails
      # served it, the app is up. An API app with no root route 404s — fine.
      if rails?(res)
        { status: :rails, code: code, detail: "Rails responded (#{code})" }
      else
        { status: :unknown, code: code, detail: "non-Rails response" }
      end
    end
  end

  # Only the body text is reliable: Plesk appends "x-powered-by: PleskLin" to
  # EVERY response (including healthy Rails apps), so that header can't be used.
  def placeholder?(res)
    res.body.to_s.include?("Domain Default page")
  end

  def rails?(res)
    res["x-request-id"].present? || res["x-runtime"].present?
  end
end
