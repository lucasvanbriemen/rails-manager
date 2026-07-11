# Holds a worker thread for the whole life of the console session — that's
# why these run on their own :console queue (see config/queue.yml) instead of
# sharing threads with deploys.
class ConsoleSessionJob < ApplicationJob
  queue_as :console

  def perform(session_id)
    session = ConsoleSession.find(session_id)
    return if session.finished? # swept as orphaned while queued

    ConsoleRunner.new(session).call
  end
end
