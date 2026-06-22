require "net/http"

# SSO against login.ltvb.nl (same scheme every ltvb app uses), plus an admin
# allowlist: this tool can create/destroy subdomains and run server commands, so
# only explicitly-listed accounts may use it. Set ADMIN_EMAILS in .env (comma
# separated). An empty allowlist denies everyone — fail closed.
module Authentication
  extend ActiveSupport::Concern

  LOGIN_URL = "https://login.ltvb.nl".freeze

  # Matches Token::TOKEN_DURATION in the login app.
  AUTH_COOKIE_DURATION = 1.week

  included do
    before_action :require_login
    helper_method :current_account
  end

  private

  attr_reader :current_account

  def require_login
    token = auth_token
    @current_account = fetch_account(token) if token.present?

    if @current_account.nil?
      return redirect_to "#{LOGIN_URL}?redirect=#{CGI.escape(request.original_url)}", allow_other_host: true
    end

    unless admin?(@current_account)
      return render plain: "Not authorized. This account may not manage apps.", status: :forbidden
    end

    # Token arrived via the URL (login redirect); persist it as a cookie and clean the URL.
    if params[:auth_token].present?
      store_auth_cookie(token)
      redirect_to clean_url
    end
  end

  def admin?(account)
    admins = ENV.fetch("ADMIN_EMAILS", "").split(",").map { |e| e.strip.downcase }.reject(&:blank?)
    email  = account["email"].to_s.downcase
    admins.include?(email)
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
