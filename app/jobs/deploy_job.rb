class DeployJob < ApplicationJob
  queue_as :default

  def perform(deployment_id, ref: nil, upload_tarball: nil)
    deployment = Deployment.find(deployment_id)
    DeployRunner.new(deployment, ref: ref, upload_tarball: upload_tarball).call
  ensure
    File.delete(upload_tarball) if upload_tarball && File.exist?(upload_tarball.to_s)
  end
end
