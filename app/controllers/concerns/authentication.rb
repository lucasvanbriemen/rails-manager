require "net/http"

module Authentication
  extend ActiveSupport::Concern

  LOGIN_URL = "https://login.ltvb.nl".freeze

  # Matches Token::TOKEN_DURATION in the login app.
  AUTH_COOKIE_DURATION = 1.week

  included do
    before_action :load_account
    helper_method :current_account, :can?, :cannot?
  end

  private

  attr_reader :current_account

  def load_account
    @current_account = fetch_account(auth_token)

    if params[:auth_token].present?
      store_auth_cookie(params[:auth_token])
      redirect_to clean_url
    end
  end

  # Permission tree login merged into the session JSON, e.g.
  # { "apps" => ["read", "update", ...], "github" => { "repositories" => [...] } }.
  # String keys/values, since it arrives as parsed JSON.
  def current_permissions
    current_account&.dig("permissions") || {}
  end

  # Is the current account allowed to perform `operation` on a permission area?
  # Flat areas: can?(:update, :apps). Nested areas: can?(:read, :github, :repositories).
  def can?(operation, *area)
    return true if Rails.env.development?

    node = current_permissions.dig(*area.map(&:to_s))
    node.is_a?(Array) && node.include?(operation.to_s)
  end

  def cannot?(operation, *area)
    !can?(operation, *area)
  end

  def forbidden
    redirect_to "#{LOGIN_URL}?redirect=#{CGI.escape(request.original_url)}", allow_other_host: true
  end

  def auth_token
    params[:auth_token].presence || cookies[:auth_token].presence || request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
  end

  # Shape of a token the login app issues. Checked BEFORE the value is put in a
  # URL: `token` arrives straight off params/cookies/headers from any anonymous
  # request, so an unvalidated value containing "../" or a query string walks the
  # path on login.ltvb.nl and makes this server issue an attacker-shaped request
  # to the SSO on every page load.
  #
  # The security property is the CHARACTER SET, not the length: excluding
  # / ? # % and whitespace is what closes traversal and query injection. The
  # bounds are only a sanity check, and the lower one is deliberately loose --
  # login.ltvb.nl issues `SecureRandom.hex(32)` (64 chars) for browser sessions
  # but also holds at least one hand-made 10-character non-expiring service
  # token. A 32-char floor would silently reject that integration.
  TOKEN_FORMAT = /\A[A-Za-z0-9_-]{8,128}\z/

  def fetch_account(token)
    return nil unless token.to_s.match?(TOKEN_FORMAT)

    response = Net::HTTP.get_response(URI("#{LOGIN_URL}/session/#{CGI.escape(token)}"))
    return nil unless response.is_a?(Net::HTTPOK)
    return nil unless response["content-type"].to_s.start_with?("application/json")

    account = JSON.parse(response.body)
    account.is_a?(Hash) && account["email"].present? ? account : nil
  rescue StandardError
    nil
  end

  def store_auth_cookie(token)
    cookies.delete(:auth_token, domain: :all)

    cookies[:auth_token] = {
      value: token,
      expires: AUTH_COOKIE_DURATION.from_now,
      httponly: true,
      secure: Rails.env.production?,
      domain: :all
    }
  end

  def clean_url
    remaining = request.query_parameters.except("auth_token")
    remaining.empty? ? request.path : "#{request.path}?#{remaining.to_query}"
  end
end
