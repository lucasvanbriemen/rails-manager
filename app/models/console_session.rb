# A live `rails console` for a managed app, run under a PTY by
# ConsoleRunner inside the jobs service. Web (Passenger) and job (systemd)
# are separate processes, so all interaction flows through this row: the UI
# polls `output` and drops commands into the `pending_input` mailbox.
class ConsoleSession < ApplicationRecord
  STATUSES = %w[queued running closed failed].freeze

  MAX_OUTPUT      = 200_000
  IDLE_TIMEOUT    = 10.minutes
  HEARTBEAT_STALE = 30.seconds
  MAX_OPEN        = 2

  belongs_to :app

  validates :status, inclusion: { in: STATUSES }

  scope :open_now, -> { where(status: %w[queued running]) }

  def finished? = %w[closed failed].include?(status)

  # Same atomic-append pattern as Deployment#append_log.
  def append_output(chunk)
    return if chunk.blank?

    self.class.where(id: id).update_all([ "output = output || ?", chunk ])
  end

  # Keep only the tail of the transcript. SQLite substr/length are
  # character-based on TEXT, so this never splits a multibyte char.
  def trim_output!
    self.class.where(id: id)
        .where("length(output) > ?", MAX_OUTPUT)
        .update_all([ "output = substr(output, length(output) - ? + 1)", MAX_OUTPUT ])
  end

  # Mailbox of one, compare-and-set: the command only lands if the session is
  # live and no other command is waiting. Returns false otherwise (UI: 409).
  def submit_input(command)
    self.class.where(id: id, status: "running", pending_input: nil)
        .update_all(pending_input: command) == 1
  end

  def request_close!
    self.class.where(id: id).update_all(close_requested: true)
  end

  def finish!(reason)
    update!(status: "closed", close_reason: reason, closed_at: Time.current,
            pending_input: nil)
  end

  # A stale heartbeat means the job loop is gone without having closed the
  # session — the jobs worker was SIGKILLed (e.g. restart on manager
  # self-deploy). Swept from controller actions; no cron needed.
  def self.sweep_orphans!
    open_now.where(heartbeat_at: [ nil, ...HEARTBEAT_STALE.ago ])
            .where(created_at: ...HEARTBEAT_STALE.ago)
            .update_all(status: "closed", close_reason: "orphaned",
                        closed_at: Time.current, pending_input: nil)
  end
end
