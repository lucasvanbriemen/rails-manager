require "test_helper"

class Api::WebhooksControllerTest < ActionDispatch::IntegrationTest
  SECRET = "s3cr3t-webhook-key"

  setup do
    @managed = App.create!(
      name: "Test app", app_kind: "rails", subdomain: "test", domain: "ltvb.nl",
      ruby_version: "3.3.8", git_repo_url: "git@github.com:x/y.git",
      git_branch: "main", primary_db_kind: "external",
      webhook_secret: SECRET, auto_deploy: true
    )
    @deliveries = 0
  end

  def post_hook(payload, secret: SECRET, event: "push", delivery: nil, token: nil)
    body = payload.to_json
    delivery ||= "d-#{@deliveries += 1}"
    sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    post "/api/webhooks/#{token || @managed.webhook_token}",
         params: body,
         headers: {
           "Content-Type" => "application/json",
           "X-Hub-Signature-256" => sig,
           "X-GitHub-Event" => event,
           "X-GitHub-Delivery" => delivery
         }
  end

  def push_payload(ref: "refs/heads/main", sha: "abc123def456", pusher: "lucas")
    { ref: ref, head_commit: { id: sha }, pusher: { name: pusher } }
  end

  # --- authentication ------------------------------------------------------

  test "a correctly signed push enqueues a deploy" do
    assert_difference -> { Deployment.count }, 1 do
      post_hook push_payload
    end
    assert_response :accepted

    delivery = @managed.webhook_deliveries.last
    assert_equal "deployed", delivery.status
    assert_equal "webhook:lucas", delivery.deployment.triggered_by
    assert_equal "deploy", delivery.deployment.kind
  end

  test "a wrong signature is rejected and deploys nothing" do
    assert_no_difference -> { Deployment.count } do
      post_hook push_payload, secret: "wrong-key"
    end
    assert_response :unauthorized
  end

  test "a missing signature header is rejected" do
    assert_no_difference -> { Deployment.count } do
      post "/api/webhooks/#{@managed.webhook_token}",
           params: push_payload.to_json,
           headers: { "Content-Type" => "application/json", "X-GitHub-Event" => "push" }
    end
    assert_response :unauthorized
  end

  test "an unknown token is rejected the same way as a bad signature" do
    # Identical response, so the endpoint can't be used to enumerate tokens.
    post_hook push_payload, token: "not-a-real-token"
    assert_response :unauthorized
  end

  test "an app with no secret configured cannot be triggered at all" do
    @managed.update!(webhook_secret: nil)
    assert_no_difference -> { Deployment.count } do
      post_hook push_payload, secret: ""
    end
    assert_response :unauthorized
  end

  test "the signature covers the body, so a tampered payload fails" do
    body = push_payload.to_json
    sig  = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", SECRET, body)
    tampered = push_payload(sha: "deadbeef").to_json

    post "/api/webhooks/#{@managed.webhook_token}", params: tampered,
         headers: { "Content-Type" => "application/json",
                    "X-Hub-Signature-256" => sig,
                    "X-GitHub-Event" => "push",
                    "X-GitHub-Delivery" => "t1" }
    assert_response :unauthorized
  end

  # --- dispatch rules ------------------------------------------------------

  test "a push to a different branch is recorded but not deployed" do
    assert_no_difference -> { Deployment.count } do
      post_hook push_payload(ref: "refs/heads/feature-x")
    end
    assert_response :accepted
    d = @managed.webhook_deliveries.last
    assert_equal "ignored", d.status
    assert_match(/feature-x/, d.message)
    assert_match(/main/, d.message)
  end

  test "webhook_branch overrides the app's git_branch" do
    @managed.update!(webhook_branch: "release")
    assert_difference -> { Deployment.count }, 1 do
      post_hook push_payload(ref: "refs/heads/release")
    end
    assert_equal "deployed", @managed.webhook_deliveries.last.status
  end

  test "auto_deploy off records the push without deploying" do
    @managed.update!(auto_deploy: false)
    assert_no_difference -> { Deployment.count } do
      post_hook push_payload
    end
    assert_equal "ignored", @managed.webhook_deliveries.last.status
  end

  test "a ping is acknowledged as wired-up, not deployed" do
    assert_no_difference -> { Deployment.count } do
      post_hook({ zen: "Keep it simple" }, event: "ping")
    end
    assert_response :accepted
    assert_equal "ignored", @managed.webhook_deliveries.last.status
  end

  test "non-push events are ignored" do
    assert_no_difference -> { Deployment.count } do
      post_hook({ action: "opened" }, event: "issues")
    end
    assert_equal "ignored", @managed.webhook_deliveries.last.status
  end

  test "an app that is unsafe to deploy is rejected, not deployed" do
    # A rails app with a blank subdomain would resolve app_path into the shared
    # webspace root, where `git reset --hard` would be catastrophic.
    @managed.update_columns(subdomain: nil)
    assert_no_difference -> { Deployment.count } do
      post_hook push_payload
    end
    assert_equal "rejected", @managed.webhook_deliveries.reload.last.status
  end

  # --- idempotence ---------------------------------------------------------

  test "a redelivered webhook does not deploy twice" do
    assert_difference -> { Deployment.count }, 1 do
      post_hook push_payload, delivery: "same-id"
      post_hook push_payload, delivery: "same-id"
    end
    assert_response :ok
    assert_equal 1, @managed.webhook_deliveries.count
  end

  test "distinct deliveries of the same commit each deploy" do
    # Two real pushes can share a head commit (e.g. a re-run); only GitHub's
    # delivery id makes them the same event.
    assert_difference -> { Deployment.count }, 2 do
      post_hook push_payload, delivery: "one"
      post_hook push_payload, delivery: "two"
    end
  end

  # --- limits --------------------------------------------------------------

  test "an oversized body is refused before any work happens" do
    huge = { ref: "refs/heads/main", pad: "x" * (5.megabytes + 1) }
    assert_no_difference -> { WebhookDelivery.count } do
      post_hook huge
    end
    assert_response :content_too_large
  end
end
