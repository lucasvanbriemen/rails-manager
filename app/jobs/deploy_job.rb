class DeployJob < ApplicationJob
  queue_as :default

  def perform(deployment_id, ref: nil)
    deployment = Deployment.find(deployment_id)
    DeployRunner.new(deployment, ref: ref).call
  end
end
