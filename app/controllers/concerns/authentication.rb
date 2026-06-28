require "net/http"

# SSO against login.ltvb.nl (same scheme every ltvb app uses). This tool can
# create/destroy subdomains and run server commands, so every privileged action
# is gated on the account's permissions for the `apps` area, delivered in the
# session JSON by login (see Permission#for there).
#
# Visitors are never blocked at the door: an unauthenticated request resolves to
# login's anonymous session (the BASE permission tree), so public read-only pages
# still render. Actions guard themselves with `cannot?(...)`, which bounces an
# anonymous visitor to login and 403s a logged-in account that lacks the right.
module Authentication
  extend ActiveSupport::Concern

  LOGIN_URL = "https://login.ltvb.nl".freeze

  # Matches Token::TOKEN_DURATION in the login app.
  AUTH_COOKIE_DURATION = 1.week

  included do
    before_action :load_account
    helper_method :current_account, :can?, :cannot?, :logged_in?
  end

  # Fail-closed session used when login is unreachable: no account, no
  # permissions. (When login *is* reachable, an unauthenticated request still
  # gets the BASE permission tree from its tokenless `/session/` fallback.)
  ANONYMOUS_SESSION = { "isloggedin" => false, "permissions" => {} }.freeze

  private

  attr_reader :current_account

  # Resolve the request's account once, before every action. A valid token
  # yields the real account; a missing/invalid token yields login's anonymous
  # BASE session; login being unreachable yields the fail-closed session above.
  # current_account is therefore always a hash, so logged_in?/can? never crash.
  def load_account
    @current_account = fetch_account(auth_token) || ANONYMOUS_SESSION

    # Token arrived via the URL (login redirect); persist it as a cookie and
    # strip it from the URL so it isn't bookmarked or leaked in referrers.
    if params[:auth_token].present?
      store_auth_cookie(params[:auth_token])
      redirect_to clean_url
    end
  end

  # A real account is one backed by a login session. An anonymous session
  # (login's tokenless fallback, or login being unreachable) carries the BASE
  # permission tree but no account — so callers can still offer a read-only view.
  def logged_in?
    current_account["isloggedin"]
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
    node = current_permissions.dig(*area.map(&:to_s))
    node.is_a?(Array) && node.include?(operation.to_s)
  end

  def cannot?(operation, *area)
    !can?(operation, *area)
  end

  # Render the 403 page. Use as an inline guard at the top of an action:
  #   return forbidden if cannot?(:read, :apps)
  def forbidden
    unless logged_in?
      return redirect_to "#{LOGIN_URL}?redirect=#{CGI.escape(request.original_url)}", allow_other_host: true
    end

    render "shared/forbidden", status: :forbidden
  end

  def auth_token
    params[:auth_token].presence ||
      cookies[:auth_token].presence ||
      request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
  end

  def fetch_account(token)
    response = Net::HTTP.get_response(URI("#{LOGIN_URL}/session/#{token}"))
    return nil unless response.is_a?(Net::HTTPOK)

    JSON.parse(response.body)
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
