# Nightly retention sweep: old occurrences go, then resolved groups whose
# occurrences are all gone. Open groups stay (their counters remain meaningful)
# even when their events have aged out.
class PruneExceptionsJob < ApplicationJob
  RETENTION = 90.days

  def perform
    ExceptionEvent.where(occurred_at: ...RETENTION.ago).delete_all
    ExceptionGroup.where(status: "resolved")
                  .where.missing(:exception_events)
                  .destroy_all
  end
end
