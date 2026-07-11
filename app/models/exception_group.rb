require "digest"

# One row per distinct error (class + failing location) per app — the Sentry
# "issue". Individual occurrences live in exception_events.
class ExceptionGroup < ApplicationRecord
  STATUSES = %w[open resolved].freeze
  MAX_EVENTS_PER_GROUP = 100

  belongs_to :app
  has_many :exception_events, -> { order(occurred_at: :desc) }, dependent: :destroy

  validates :fingerprint, :exception_class, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :open_status, -> { where(status: "open") }
  scope :recent, -> { order(last_seen_at: :desc) }

  def open? = status == "open"
  def resolved? = status == "resolved"

  def resolve! = update!(status: "resolved")
  def reopen!  = update!(status: "open")

  # Record one reported occurrence: find-or-create the group, append the event,
  # bump counters. A resolved group that recurs reopens — that's a regression.
  def self.record!(app, exception_class:, message:, backtrace:, context:, occurred_at:)
    group = app.exception_groups.find_or_initialize_by(
      fingerprint: fingerprint_for(exception_class, backtrace)
    )
    group.exception_class = exception_class
    group.message         = message
    group.first_seen_at ||= occurred_at
    group.last_seen_at    = occurred_at
    group.events_count   += 1
    group.status          = "open"
    group.save!

    group.exception_events.create!(
      message: message,
      backtrace: Array(backtrace).join("\n"),
      context: context.to_json,
      occurred_at: occurred_at
    )
    group.prune_events!
    group
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  # Same error class raised from the same app-level frame = same issue.
  # Fall back to the first frame (or none) so C-extension/frameless errors
  # still group by class.
  def self.fingerprint_for(exception_class, backtrace)
    frames = Array(backtrace)
    anchor = frames.find { |f| f.to_s.start_with?("app/", "./app/") || f.to_s.include?("/app/") } || frames.first
    Digest::SHA256.hexdigest("#{exception_class}|#{anchor}")[0, 32]
  end

  def prune_events!
    overflow = exception_events.count - MAX_EVENTS_PER_GROUP
    return unless overflow.positive?

    exception_events.order(occurred_at: :asc).limit(overflow).delete_all
  end
end
