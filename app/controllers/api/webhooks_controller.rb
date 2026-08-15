module Api
  # Git push webhooks. Replaces the root cron that polled Plesk's git-extension
  # SQLite every minute — a design that existed only because Plesk's own
  # post-deploy actions never fired on webhook deploys.
  #
  # Deliberately outside the SSO: the caller is GitHub, not a browser. The
  # authentication is the HMAC signature over the raw body, NOT the token in
  # the URL — the token only selects which app's secret to verify against, so
  # a leaked URL alone cannot trigger a deploy.
  class WebhooksController < ActionController::API
    MAX_BODY = 5.megabytes

    def create
      return head :content_too_large if request.raw_post.bytesize > MAX_BODY

      app = App.find_by(webhook_token: params[:token].to_s)
      # Same response whether the token is unknown or the signature is wrong,
      # so this endpoint can't be used to enumerate valid tokens.
      return head :unauthorized unless app && verified?(app)

      delivery = record(app)
      return head :ok if delivery.nil? # duplicate delivery, already handled

      handle(app, delivery)
      head :accepted
    end

    private

    # GitHub signs the RAW body. Compare in constant time, and treat a missing
    # or malformed header as a failure rather than skipping the check.
    def verified?(app)
      secret = app.webhook_secret.presence
      return false if secret.blank?

      sent = request.headers["X-Hub-Signature-256"].to_s
      return false unless sent.start_with?("sha256=")

      expected = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, request.raw_post)
      ActiveSupport::SecurityUtils.secure_compare(sent, expected)
    rescue StandardError
      false
    end

    # Returns nil when this delivery id has already been seen. The unique index
    # on [provider, external_id] is what makes a GitHub retry idempotent —
    # relying on an in-process check would race between Puma workers.
    def record(app)
      app.webhook_deliveries.create!(
        provider:    "github",
        event:       request.headers["X-GitHub-Event"].to_s.presence,
        external_id: request.headers["X-GitHub-Delivery"].to_s.presence,
        ref:         params[:ref].to_s.presence,
        commit_sha:  params.dig(:head_commit, :id).to_s.presence,
        pusher:      params.dig(:pusher, :name).to_s.presence,
        status:      "received"
      )
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def handle(app, delivery)
      if delivery.event == "ping"
        return delivery.update!(status: "ignored", message: "ping — webhook is wired up correctly")
      end

      unless delivery.event == "push"
        return delivery.update!(status: "ignored", message: "event #{delivery.event.inspect} is not a push")
      end

      unless app.auto_deploy?
        return delivery.update!(status: "ignored", message: "auto-deploy is off for this app")
      end

      wanted = app.webhook_branch.presence || app.git_branch
      unless delivery.branch == wanted
        return delivery.update!(status: "ignored",
                                message: "pushed #{delivery.branch.inspect}, this app tracks #{wanted.inspect}")
      end

      if (reason = app.undeployable_reason)
        return delivery.update!(status: "rejected", message: "refusing to deploy: #{reason}")
      end

      deployment = app.deployments.create!(
        kind: "deploy",
        triggered_by: "webhook:#{delivery.pusher.presence || 'github'}"
      )
      DeployJob.perform_later(deployment.id, ref: nil)
      delivery.update!(status: "deployed", deployment: deployment)
    end
  end
end
