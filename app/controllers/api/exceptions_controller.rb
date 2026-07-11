module Api
  # Ingest endpoint for the error-reporter snippet managed apps run in
  # production. Authenticated by the per-app ingest token, not by the login
  # session — reports come from servers, not browsers.
  class ExceptionsController < ActionController::API
    EVENTS_PER_MINUTE = 60
    MAX_FRAMES = 50

    def create
      app = App.find_by(ingest_token: token)
      return head :unauthorized unless app
      return head :too_many_requests if rate_limited?(app)

      ExceptionGroup.record!(
        app,
        exception_class: params.require(:class).to_s.first(200),
        message: params[:message].to_s.first(2000),
        backtrace: frames,
        context: context,
        occurred_at: occurred_at
      )
      head :accepted
    rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid
      head :unprocessable_entity
    end

    private

    def token
      params[:token].presence || request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
    end

    def frames
      Array(params[:backtrace]).first(MAX_FRAMES).map { |f| f.to_s.first(500) }
    end

    # Whatever hash the reporter sent (request url, job class, severity,
    # handled flag…), stored as JSON — clamped so one report can't balloon.
    def context
      raw = params[:context].respond_to?(:to_unsafe_h) ? params[:context].to_unsafe_h : {}
      raw = {} unless raw.is_a?(Hash)
      raw["handled"]  = params[:handled] unless params[:handled].nil?
      raw["severity"] = params[:severity].to_s if params[:severity].present?
      raw.to_json.size > 10_000 ? { "note" => "context too large, dropped" } : raw
    end

    def occurred_at
      Time.iso8601(params[:occurred_at].to_s)
    rescue ArgumentError
      Time.current
    end

    # An error loop in one app must not flood the manager's SQLite. Excess
    # reports are dropped; the group's counts just undercount during a storm.
    def rate_limited?(app)
      key = "exception-ingest:#{app.id}:#{Time.current.strftime('%Y%m%d%H%M')}"
      count = Rails.cache.increment(key, 1, expires_in: 2.minutes)
      count.present? && count > EVENTS_PER_MINUTE
    end
  end
end
