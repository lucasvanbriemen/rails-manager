require "net/http"

# Classifies what an app's URL actually serves right now. The whole point of the
# manager: catch the git.ltvb.nl failure mode (Plesk serving its default
# placeholder because Passenger never found the app) automatically.
module AppStatusChecker
  # Statuses considered "up" — a Rails response, or a redirect (e.g. the SSO
  # bounce to login.ltvb.nl, which is the expected state for gated apps).
  HEALTHY = %i[rails redirect].freeze

  module_function

  # => { status: Symbol, code: Integer|nil, detail: String }
  def check(app)
    uri = URI(app.url)
    res = request(uri)
    classify(res)
  rescue StandardError => e
    { status: :down, code: nil, detail: e.message }
  end

  def request(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 5
    http.read_timeout = 5
    http.get(uri.request_uri.presence || "/")
  end

  def classify(res)
    code = res.code.to_i

    case code
    when 300..399
      { status: :redirect, code: code, detail: "→ #{res["location"]}" }
    when 500..599
      { status: :error5xx, code: code, detail: "server error" }
    when 200..299
      if placeholder?(res)
        { status: :placeholder, code: code, detail: "Plesk default page — Passenger not serving the app" }
      else
        { status: :rails, code: code, detail: rails?(res) ? "Rails (x-request-id present)" : "app responded" }
      end
    else
      { status: :unknown, code: code, detail: "unexpected status" }
    end
  end

  def placeholder?(res)
    res["x-powered-by"].to_s.include?("PleskLin") ||
      res.body.to_s.include?("Domain Default page")
  end

  def rails?(res)
    res["x-request-id"].present? || res["x-runtime"].present?
  end
end
