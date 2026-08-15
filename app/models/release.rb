# A single built release directory. The point of the record is not bookkeeping:
# it is knowing, at 3am when a deploy has just broken the site, which directory
# on disk was last proven to serve traffic. See ReleaseLayout for the on-disk
# shape and ReleaseLayout::Promotion for the swap that consumes `rollback_target`.
class Release < ApplicationRecord
  # Raised instead of quietly returning a release that belongs to another app.
  class CrossApp < StandardError; end

  BUILDING    = "building".freeze     # directory exists, steps still running
  LIVE        = "live".freeze         # `current` points here
  SUPERSEDED  = "superseded".freeze   # was live, replaced by a newer healthy one
  FAILED      = "failed".freeze       # never promoted (build or health failed)
  ROLLED_BACK = "rolled_back".freeze  # was promoted, failed health, swapped off

  STATUSES = [ BUILDING, LIVE, SUPERSEDED, FAILED, ROLLED_BACK ].freeze

  # Only a release that actually served traffic and was retired *cleanly* is a
  # safe rollback destination. FAILED never booted; ROLLED_BACK is the one we
  # just fled from — rolling back onto either would re-break the site.
  KNOWN_GOOD = [ SUPERSEDED ].freeze

  # What a rollback may land on. LIVE is in the set on purpose: the fallback is
  # chosen BEFORE the symlink swap, and at that moment the release we would have
  # to return to is the one still flagged LIVE — nothing has superseded it yet.
  # Leaving it out returned the release *before* the one serving traffic, so a
  # single bad deploy rolled the site back two deploys.
  ROLLBACK_TO = ([ LIVE ] + KNOWN_GOOD).freeze

  # Release directories kept on disk. Five is roughly a week of deploys for the
  # busiest app here and, with vendor/bundle hardlinked between them, costs far
  # less disk than five full copies.
  KEEP = 5

  belongs_to :app
  belongs_to :deployment, optional: true

  validates :path, presence: true, uniqueness: { scope: :app_id }
  validates :status, inclusion: { in: STATUSES }

  # Newest first. id breaks the tie because two releases created inside the same
  # second sort arbitrarily otherwise, and prune/rollback both depend on order.
  scope :ordered,    -> { order(created_at: :desc, id: :desc) }
  scope :current,    -> { where(status: LIVE) }
  scope :previous,   -> { where(status: [ SUPERSEDED, ROLLED_BACK ]).ordered }
  scope :known_good, -> { where(status: KNOWN_GOOD).ordered }
  scope :in_flight,  -> { where(status: BUILDING) }

  # The release to swap `current` back to when a promotion fails its health
  # check. Newest first over ROLLBACK_TO, skipping any whose directory has since
  # been pruned or manually deleted — pointing `current` at a missing path would
  # take the site down harder than the bad deploy did.
  #
  # Ask for this BEFORE promoting the new release: that is when the live row is
  # still the code that was serving, which is what makes LIVE a candidate.
  #
  # WHY the app is mandatory: the answer becomes the target of a symlink swap
  # inside one webspace. An unscoped class method returns the newest candidate in
  # the whole table, so a rollback of git.ltvb.nl could point its `current` at a
  # release directory belonging to another subscription entirely — a path its uid
  # cannot even read. Nothing here is expensive enough to justify that risk.
  def self.rollback_target(app)
    app_id = app.is_a?(App) ? app.id : app
    if app_id.blank?
      raise ArgumentError, "rollback_target needs an app: an unscoped rollback can point one site at another's release"
    end

    # Narrowing by app_id would make a relation scoped to a DIFFERENT app return
    # nothing, and a caller reads nil as "no fallback, leave the broken release
    # live". Being wrong about which app we are rolling back is a bug worth
    # crashing on, not one worth answering.
    scoped = Array(all.where_values_hash["app_id"]).map(&:to_s)
    unless scoped.empty? || scoped == [ app_id.to_s ]
      raise CrossApp, "refusing a rollback target for app #{app_id} from releases scoped to app #{scoped.join(', ')}"
    end

    where(app_id: app_id).where(status: ROLLBACK_TO).ordered.detect(&:on_disk?)
  end

  # Releases whose directories may be deleted. Everything protected is protected
  # for a reason, so this is deliberately conservative:
  #   - the newest `keep` releases (the actual retention policy)
  #   - whatever is live or still building (deleting either breaks a running app)
  #   - the newest known-good release, even if it falls outside `keep`, because
  #     it is the rollback target and retention must never eat the safety net
  # Pure SQL on purpose: prune decisions are tested without touching the disk.
  def self.prunable(keep: KEEP)
    ordered.where.not(id: protected_ids(keep: keep))
  end

  def self.protected_ids(keep: KEEP)
    ids  = ordered.limit(keep).ids
    ids |= where(status: [ LIVE, BUILDING ]).ids
    ids |= [ known_good.first&.id ].compact
    ids
  end

  # Promote this release. Any release still flagged LIVE is demoted to
  # SUPERSEDED — but only if it is still LIVE, so a rollback (which marks the
  # bad release ROLLED_BACK first, then re-promotes the old one) does not
  # quietly relabel the failure as a clean supersede.
  def mark_live!(at: Time.current)
    self.class.transaction do
      self.class.where(app_id: app_id, status: LIVE).where.not(id: id)
          .update_all(status: SUPERSEDED, superseded_at: at, updated_at: at)
      update!(status: LIVE, deployed_at: deployed_at || at, superseded_at: nil)
    end
  end

  def mark_rolled_back!(at: Time.current)
    update!(status: ROLLED_BACK, superseded_at: at)
  end

  def mark_failed!
    update!(status: FAILED)
  end

  def record_build!(duration_ms: nil, size_bytes: nil)
    update!(build_duration_ms: duration_ms, size_bytes: size_bytes)
  end

  def live?        = status == LIVE
  def building?    = status == BUILDING
  def known_good?  = KNOWN_GOOD.include?(status)
  def on_disk?     = path.present? && Dir.exist?(path)

  # releases/20260815143000 -> "20260815143000"; also the sort key on disk.
  def name = File.basename(path.to_s)

  def short_ref = git_ref.to_s[0, 8].presence

  def build_duration_seconds
    build_duration_ms && build_duration_ms / 1000.0
  end
end
