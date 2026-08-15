# One backup run. See CreateBackups for why the table exists at all; this class
# owns two decisions that must not be improvised at 3am:
#
#   1. RETENTION — which runs may be deleted. Documented as a grandfather-
#      father-son schedule below, computed in pure Ruby from timestamps, and
#      deliberately conservative about the one backup that has actually been
#      proven restorable.
#   2. VERIFICATION STATE — what "last verified" means on the dashboard, and the
#      refusal to let a run that was never verified look like one that was.
class Backup < ApplicationRecord
  RUNNING   = "running".freeze    # directory exists, phases still running
  SUCCEEDED = "succeeded".freeze  # every phase completed
  PARTIAL   = "partial".freeze    # something was unreadable; the rest is here
  FAILED    = "failed".freeze     # the run aborted

  STATUSES = [ RUNNING, SUCCEEDED, PARTIAL, FAILED ].freeze

  # A partial run still holds real dumps, so it is a restore candidate and is
  # retained like any other. A failed one is not: retaining it would let a
  # directory of half-written files satisfy the "we have 7 dailies" rule.
  USABLE = [ SUCCEEDED, PARTIAL ].freeze

  VERIFY_PENDING = "pending".freeze  # not attempted yet (or still running)
  VERIFY_PASSED  = "passed".freeze   # restored into a scratch DB and compared
  VERIFY_FAILED  = "failed".freeze   # the restore or the comparison disagreed
  VERIFY_SKIPPED = "skipped".freeze  # deliberately not attempted this run

  VERIFY_STATUSES = [ VERIFY_PENDING, VERIFY_PASSED, VERIFY_FAILED, VERIFY_SKIPPED ].freeze

  # ---- retention -----------------------------------------------------------
  #
  # Grandfather-father-son, counted in *distinct buckets that exist* rather than
  # in days elapsed. The difference matters here: this server's backups will be
  # driven by a nightly timer that can and will miss nights (a reboot, a full
  # disk, a broken deploy), and a policy phrased as "delete anything older than
  # 7 days" turns a fortnight of missed runs into zero backups. Phrased as
  # "keep the newest run in each of the 7 most recent days that HAVE one", the
  # same fortnight leaves the last good backup alone.
  #
  # 7 dailies + 4 weeklies + 6 monthlies is ~17 directories. Sized against what
  # a run MEASURABLY costs on this box, because the arithmetic is what makes the
  # policy affordable or not:
  #
  #   ~400 MB  gitub_gui once incoming_webhooks is excluded
  #   ~37 MB   email.lucasvanbriemen.nl (38,518,542 bytes gz, measured — it is
  #            the largest dumpable database and it is not the 420 MB an earlier
  #            version of this comment claimed)
  #   ~130 MB  SQLite across 7 apps
  #   ~144 MB  /var/qmail/mailnames, the Maildirs
  #   ~150 MB  app files and the rest of the system config
  #
  # ...so ~900 MB per run and ~15 GB retained, against 274 GB free. That holds
  # ONLY with BackupRunner::APP_FILE_EXCLUSIONS applied: `storage` is in
  # RUBY_APP_FILES and one app's storage is 6.74 GB of mp3 and model cache that
  # gzip does not compress (measured ratio 0.996), which would make a run ~6.9 GB
  # and 17 retained runs ~118 GB. Including the 18.25 GB webhook table on top
  # would make it ~320 GB. Both exclusions are named, reasoned and recorded for
  # that reason — and all of it lands on /dev/vda1, the same single filesystem
  # as the data it protects, so nothing here is a substitute for a copy off-box.
  RETENTION = { daily: 7, weekly: 4, monthly: 6 }.freeze

  # How long a run may sit at `running` before it is treated as abandoned. A
  # `running` row is never pruned — it is being written to — so without a bound
  # one process killed by OOM, a reboot or a deploy mid-run protects its
  # directory for the rest of the server's life and takes a retention slot with
  # it. Comfortably longer than any real run: the whole thing is ~1 GB.
  RUNNING_GRACE = 24.hours

  # How stale the newest VERIFIED backup may be before somebody has to be told.
  # One nightly run plus a missed night: past that, the timer, the run or the
  # verification has been broken for a day and nothing has said so, which is the
  # exact failure this class exists to make impossible.
  MAX_VERIFIED_AGE = 36.hours

  # ISO week for the weekly bucket (%G/%V, not %Y/%W): using the calendar year
  # with an ISO week number puts the last days of December in "2026-W01" and
  # collapses two different weeks into one bucket.
  BUCKETS = { daily: "%Y-%m-%d", weekly: "%G-W%V", monthly: "%Y-%m" }.freeze

  validates :path, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :verify_status, inclusion: { in: VERIFY_STATUSES }

  # Newest first; id breaks the tie because two runs started in the same second
  # sort arbitrarily otherwise and retention depends on the order.
  scope :ordered,  -> { order(started_at: :desc, id: :desc) }
  scope :usable,   -> { where(status: USABLE) }
  scope :on_disk,  -> { where(pruned_at: nil) }
  scope :verified, -> { where(verify_status: VERIFY_PASSED) }

  def self.latest = ordered.first

  # The last run that was actually restored and compared. This is the number the
  # dashboard should show, not `latest` — "backed up 6 hours ago" next to "last
  # proven restorable 5 weeks ago" is the only honest pair of statements.
  def self.last_verified = verified.on_disk.order(verified_at: :desc).first

  # True when nobody has proved a restore recently enough. Deliberately true for
  # "never", because a server that has never proved a restore and a server whose
  # last proof is six weeks old are in the same position, and the dashboard must
  # not read as reassuring in either.
  def self.verification_overdue?(now: Time.current)
    last = last_verified
    last.nil? || last.verified_at.nil? || last.verified_at < now - MAX_VERIFIED_AGE
  end

  # One line, phrased so it can be printed as-is by the rake task or shown on
  # the dashboard, and never phrased as reassurance it cannot support.
  def self.verification_summary(now: Time.current)
    last = last_verified
    return "NO backup has ever been proven to restore" if last.nil? || last.verified_at.nil?

    hours   = ((now - last.verified_at) / 1.hour).floor
    overdue = verification_overdue?(now: now) ? " — OVERDUE, the limit is #{(MAX_VERIFIED_AGE / 1.hour).to_i}h" : ""
    "last proven restorable #{hours}h ago: #{last.verify_database}, " \
      "#{last.verify_tables} tables/#{last.verify_rows} rows#{overdue}"
  end

  # Rows whose directories may be deleted.
  #
  # Everything protected is protected for a reason:
  #   - the newest run in each of the most recent RETENTION[:daily] days that
  #     has one, and likewise per ISO week and per month;
  #   - the newest VERIFIED run, whatever its age, because it is the only backup
  #     anybody has proof about and retention must never eat the evidence (same
  #     rule, and the same reasoning, as Release.protected_ids keeping the
  #     rollback target alive past `keep`);
  #   - anything still running, which is being written to right now;
  #   - the newest usable run, even if the schedule would not reach it.
  #
  # A failed run is NOT protected: its directory holds half-written files, and
  # everything worth keeping about it (the log, the error, what it got through)
  # is on the row, which pruning never touches.
  def self.prunable(now: Time.current)
    # `on_disk` (pruned_at IS NULL) is a claim about the ROW. `on_disk?` is a
    # question about the DISK, and they disagree the moment a directory goes by
    # any route other than prune! — a manual rm, a restored manager database, a
    # filesystem that was rebuilt. While they disagree, the vanished row holds
    # the "newest usable" and "newest verified" protections that exist to guard
    # bytes, and real directories get deleted to make room for the memory of one
    # that is not there. See BackupRunner#reconcile_ghosts! for the other half.
    candidates = on_disk.ordered.to_a.select(&:on_disk?)
    keep = keep_ids(candidates, now: now)
    candidates.reject { |backup| keep.include?(backup.id) }
  end

  # Rows the table still counts as on disk whose directory is gone.
  def self.ghosts = on_disk.ordered.to_a.reject(&:on_disk?)

  # A run still `running` long after any real run could be is a run that was
  # killed. Recording that is what lets retention treat it as the failure it is;
  # leaving it alone protects its directory forever. A row with no started_at is
  # left alone: its age is not a thing we know, and the same rule as the
  # future-dated rows applies — do not act on a timestamp you cannot explain.
  def self.abandon_stale_runs!(now: Time.current)
    where(status: RUNNING).where.not(started_at: nil)
                          .where(started_at: ...(now - RUNNING_GRACE)).to_a.each do |backup|
      backup.finish!(FAILED, at: now,
                     error: "abandoned: still `running` more than #{RUNNING_GRACE.inspect} after " \
                            "#{backup.started_at.utc.iso8601}, so the process that was writing it is gone")
    end
  end

  # Pure over the rows it is given, so the schedule is tested against a table of
  # timestamps rather than against the clock.
  def self.keep_ids(backups, now: Time.current)
    keep = Set.new
    # Bounded by RUNNING_GRACE: a run in flight is being written to and must be
    # left alone, but a row that has said `running` for a day is a corpse and
    # protecting it forever is how one killed process pins a directory.
    keep.merge(backups.select { |backup| backup.running? && backup.protected_while_running?(now: now) }
                      .map(&:id))

    newest_first = backups.select { |backup| backup.usable? && backup.started_at }
                          .sort_by { |backup| [ backup.started_at, backup.id ] }.reverse

    # A row timestamped in the future is a clock problem, not a backup. It is
    # kept out of the buckets — it would hold the newest daily slot forever and
    # push a real backup out of the window — and kept on disk anyway, because
    # deleting a directory whose timestamp we cannot explain is not retention.
    future, dated = newest_first.partition { |backup| backup.started_at > now }
    keep.merge(future.map(&:id))

    keep << dated.first&.id
    keep << dated.find(&:verified?)&.id

    RETENTION.each do |tier, count|
      format = BUCKETS.fetch(tier)
      seen = {}
      dated.each do |backup|
        # Bucketed in UTC: a backup taken at 00:30 CEST belongs to the previous
        # UTC day, and a bucket key that shifts with the server's timezone would
        # re-bucket every row twice a year.
        bucket = backup.started_at.utc.strftime(format)
        next if seen.key?(bucket) || seen.size >= count

        seen[bucket] = backup.id
      end
      keep.merge(seen.values)
    end

    keep.delete(nil)
    keep
  end

  # ---- state ---------------------------------------------------------------

  def running?   = status == RUNNING

  # A running row protects its directory only while the run could plausibly
  # still be running. Unknown start time counts as protected: acting on a
  # timestamp we cannot explain is guessing, not retention.
  def protected_while_running?(now: Time.current) = started_at.nil? || started_at > now - RUNNING_GRACE

  def usable?    = USABLE.include?(status)
  def verified?  = verify_status == VERIFY_PASSED
  def pruned?    = pruned_at.present?
  def on_disk?   = pruned_at.nil? && path.present? && Dir.exist?(path)

  def name = File.basename(path.to_s)

  def duration_seconds
    return nil unless started_at && finished_at

    finished_at - started_at
  end

  # Manifest and exclusion rows come back out of the json column string-keyed
  # however they went in, so both are handed out indifferent-access.
  def manifest_entries = indifferent(manifest)

  def exclusion_entries = indifferent(excluded)

  def entries_of_kind(kind)
    manifest_entries.select { |entry| entry[:kind].to_s == kind.to_s }
  end

  # What is deliberately NOT in this backup, rendered for a human. Never
  # collapses to "" when there are exclusions: silence is the failure mode this
  # whole column exists to prevent.
  def exclusion_summary
    rows = exclusion_entries
    return [ "nothing excluded — every database and table was dumped in full" ] if rows.empty?

    rows.map do |row|
      # `target` is written by both exclusion structs; the fallback is for rows
      # from a manifest taken before file exclusions existed.
      target = row[:target].presence || [ row[:database], row[:table] ].compact_blank.join(".")
      "#{target}: #{row[:mode]} (#{row[:reason]})"
    end
  end

  def append_log(message)
    self.log = "#{log}#{message}"
    # update_column, not update!: the log is written from inside a long run and
    # must not trip validations or touch updated_at on every line.
    update_column(:log, log) if persisted?
    message
  end

  def finish!(status, at: Time.current, error: nil)
    update!(status: status, finished_at: at, error: error)
  end

  # Recorded together, always: a verified_at without the counts it was based on
  # is a claim rather than evidence.
  def record_verification!(passed:, database:, tables: nil, rows: nil, detail: nil, at: Time.current)
    update!(verify_status: passed ? VERIFY_PASSED : VERIFY_FAILED,
            verified_at: at, verify_database: database,
            verify_tables: tables, verify_rows: rows, verify_detail: detail)
  end

  def skip_verification!(reason)
    update!(verify_status: VERIFY_SKIPPED, verify_detail: reason)
  end

  def mark_pruned!(at: Time.current)
    update!(pruned_at: at)
  end

  private

  def indifferent(rows)
    Array(rows).map { |row| row.is_a?(Hash) ? row.with_indifferent_access : row }
  end
end
