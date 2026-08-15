class DeployJob < ApplicationJob
  queue_as :default

  # The app (and with it the deployment) was destroyed while this sat in the
  # queue. There is nothing left to deploy, so this is not a failure to retry.
  discard_on ActiveRecord::RecordNotFound

  # WHY there is no retry_on: DeployRunner does not raise. It records the failure
  # on the Deployment, leaves `current` wherever it is safe to leave it, and
  # returns false. Anything that escapes it got past two rescue clauses, which
  # means this worker is broken rather than the deploy — and re-running a deploy
  # that got halfway is exactly how a half-built site happens.
  def perform(deployment_id, ref: nil)
    DeployRunner.new(Deployment.find(deployment_id), ref: ref).call
  end
end
