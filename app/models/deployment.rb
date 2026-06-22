class Deployment < ApplicationRecord
  KINDS    = %w[create deploy restart migrate_primary destroy].freeze
  STATUSES = %w[queued running succeeded failed].freeze

  belongs_to :app

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def running? = status == "running"
  def finished? = %w[succeeded failed].include?(status)

  def start!
    update!(status: "running", started_at: Time.current)
  end

  def finish!(success)
    update!(status: success ? "succeeded" : "failed", finished_at: Time.current)
  end

  # Append a chunk of output to the persisted log. The live view polls for
  # updates (robust under Passenger, no websocket dependency).
  def append_log(chunk)
    return if chunk.blank?

    self.class.where(id: id).update_all([ "log = log || ?", chunk ])
  end

  def duration
    return unless started_at

    ((finished_at || Time.current) - started_at).round
  end
end
