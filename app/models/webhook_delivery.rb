# One inbound webhook, recorded whether or not it led to a deploy. This is the
# audit trail that replaces "did the cron notice my push?" — every delivery has
# a visible outcome and a reason.
class WebhookDelivery < ApplicationRecord
  STATUSES = %w[received deployed ignored rejected duplicate].freeze

  belongs_to :app
  belongs_to :deployment, optional: true

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def short_sha = commit_sha.to_s.first(7)

  # refs/heads/main => main
  def branch = ref.to_s.delete_prefix("refs/heads/")
end
