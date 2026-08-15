require "fileutils"

# The Capistrano-style on-disk layout that lets a deploy fail without taking the
# site with it.
#
#   /var/www/vhosts/ltvb.nl/git.ltvb.nl/
#     current -> releases/20260815143000     <- the ONLY path a vhost points at
#     releases/
#       20260815143000/                      <- immutable once promoted
#       20260815120500/
#     shared/                                <- survives every release
#       .env  config/master.key  log  storage  public/uploads
#       vendor/bundle  node_modules           <- seeds, see #seeds
#     deploy.lock
#
# Everything here is path arithmetic plus three filesystem operations that have
# to be exactly right: the atomic swap (#swap!), the deploy lock
# (#with_deploy_lock) and release removal (#remove_release!). ReleaseLayout::
# Promotion wraps the swap with a health check and the rollback.
class ReleaseLayout
  # Lexically sortable, second-resolution, UTC. Matches Capistrano so anyone who
  # has seen a releases/ directory before can read ours.
  TIMESTAMP_FORMAT = "%Y%m%d%H%M%S".freeze

  # Kinds that get the release layout. A repo (ui-components) is a plain checkout
  # at a hand-configured path that other apps mount directly — introducing a
  # `current` symlink under it would break every consumer's include path.
  LAYOUT_KINDS = %w[rails laravel php static cron].freeze

  class Locked < StandardError; end
  class UnsafePath < StandardError; end

  # A symlink pointing out of the release into shared/.
  Link = Struct.new(:link, :target, :kind, keyword_init: true) do
    def dir? = kind == :dir
  end

  # A directory hardlink-copied out of shared/ into the release before the build.
  Seed = Struct.new(:source, :dest, keyword_init: true)

  def self.applies_to?(app)
    LAYOUT_KINDS.include?(app.app_kind)
  end

  def initialize(app, now: Time.now.utc)
    @app = app
    @now = now.utc
  end

  attr_reader :app

  # ---- paths ---------------------------------------------------------------

  def root          = app.app_path
  def releases_path = File.join(root, "releases")
  def shared_path   = File.join(root, "shared")
  def current_path  = File.join(root, "current")
  def lock_path     = File.join(root, "deploy.lock")

  # The staging name for the swap. Must live in the same directory as `current`:
  # rename(2) is only atomic within one filesystem, and this guarantees it.
  def staged_current_path = "#{current_path}.tmp"

  def release_name(at = @now) = at.utc.strftime(TIMESTAMP_FORMAT)
  def release_path(name)      = File.join(releases_path, name.to_s)
  def new_release_path        = release_path(release_name)

  # What the web server's DocumentRoot must become. Note it goes through
  # `current`, never through a release: the vhost is written once and never
  # touched again, and the swap is what changes which code is served.
  def document_root
    suffix = app.doc_root_suffix.presence
    suffix ? File.join(current_path, suffix) : current_path
  end

  # Where a release's own docroot lands, for the steps that write into it
  # (assets:precompile, storage:link).
  def release_document_root(path)
    suffix = app.doc_root_suffix.presence
    suffix ? File.join(path, suffix) : path
  end

  # ---- shared state --------------------------------------------------------

  # Symlinked out of shared/ into every release: things whose *identity* must
  # survive a deploy. The sqlite file, user uploads and the log stream have to be
  # the same inode next release, and the secrets are not in git at all.
  def shared_dirs
    case app.app_kind
    when "rails"           then [ "log", "storage", uploads_dir ]
    when "laravel"         then [ "storage", uploads_dir ]
    when "cron"            then [ "storage" ]
    when "php"             then [ uploads_dir ]
    else                        []
    end
  end

  def shared_files
    case app.app_kind
    when "rails"                    then [ ".env", "config/master.key" ]
    when "laravel", "php", "cron"   then [ ".env" ]
    else                                 []
    end
  end

  # Uploads live under the document root, wherever that is for this kind: a
  # Rails/Laravel app serves from public/, a plain PHP site from its own root.
  def uploads_dir
    File.join(app.doc_root_suffix.presence.to_s, "uploads").delete_prefix("/")
  end

  # Build caches that are per-release rather than shared, seeded from shared/
  # with `cp -al` (hardlinks).
  #
  # WHY hardlinks instead of a shared symlink: `bundle install` and `npm ci`
  # MUTATE these trees. If the running release symlinks the same vendor/bundle,
  # a build for the next release deletes gems out from under the process that is
  # serving requests right now — which is exactly the class of failure atomic
  # releases exist to remove (and how a stale default-gem copy poisoned
  # git.ltvb.nl's Passenger spawns). A full copy would be correct but costs a
  # gigabyte and a minute per deploy. `cp -al` creates a new directory tree whose
  # files are extra names for the SAME inodes: near-instant, near-zero disk, and
  # safe — bundler replaces gems by unlinking and writing new files, which drops
  # only this release's name for the old inode and leaves the running release's
  # copy intact. Only in-place rewriting of a file's bytes would leak across, and
  # neither bundler nor npm does that.
  def seeded_dirs
    case app.app_kind
    when "rails"           then [ "vendor/bundle", "node_modules" ]
    when "laravel", "cron" then [ "vendor", "node_modules" ]
    when "php"             then [ "vendor" ]
    else                        []
    end
  end

  # Symlinks to create inside a freshly checked-out release.
  def links(path)
    dirs  = shared_dirs.map  { |rel| Link.new(link: File.join(path, rel), target: File.join(shared_path, rel), kind: :dir) }
    files = shared_files.map { |rel| Link.new(link: File.join(path, rel), target: File.join(shared_path, rel), kind: :file) }
    dirs + files
  end

  def seeds(path)
    seeded_dirs.map { |rel| Seed.new(source: File.join(shared_path, rel), dest: File.join(path, rel)) }
  end

  # Every directory that must exist in shared/ before the first release links
  # into it. Includes the parent of each shared *file* (shared/config, so
  # master.key has somewhere to be written) — a dangling symlink into a missing
  # directory is the failure mode this list exists to prevent.
  def shared_skeleton
    dirs  = shared_dirs + seeded_dirs
    dirs += shared_files.map { |f| File.dirname(f) }.reject { |d| d == "." }
    dirs.uniq.sort.map { |rel| File.join(shared_path, rel) }
  end

  # ---- the atomic swap -----------------------------------------------------

  # Point `current` at `target`.
  #
  # WHY not `ln -sfn`: for an existing symlink, `ln -sfn` is unlink(2) followed
  # by symlink(2). Between those two syscalls `current` does not exist, so every
  # request in flight resolves a DocumentRoot that is gone — a burst of 403/404
  # or, for PHP-FPM, a hard 502. rename(2) instead REPLACES the directory entry
  # in one step, so the entry is never absent: a concurrent lookup sees either
  # the old release or the new one. Ruby's File.rename is rename(2) with no
  # fallback, and staging the new link in the SAME directory keeps it on one
  # filesystem, which is what rename(2) requires to be atomic.
  def swap!(target)
    stage_current!(target)
    commit_current!
    target
  rescue StandardError
    # A failed swap must leave `current` exactly as it was; drop the debris.
    File.unlink(staged_current_path) if File.symlink?(staged_current_path)
    raise
  end

  # Build the replacement link under a temporary name. `current` is deliberately
  # untouched here — this is precisely the half of the job that `ln -sfn` does by
  # deleting `current` first.
  def stage_current!(target)
    staged = staged_current_path
    File.unlink(staged) if File.symlink?(staged) || File.exist?(staged)
    File.symlink(target, staged)
    staged
  end

  # One syscall, no window.
  def commit_current!
    File.rename(staged_current_path, current_path)
  end

  # What `current` resolves to right now, or nil if it was never created.
  def current_target
    File.readlink(current_path) if File.symlink?(current_path)
  end

  # ---- pruning -------------------------------------------------------------

  # Delete a release directory. `rm -rf` under a webspace root is the single most
  # dangerous thing this manager does, so refuse anything that is not literally a
  # child of releases/ — a symlinked, traversing or absolute path from a bad
  # record must not be able to reach /var/www/vhosts or the live `current`.
  def remove_release!(path)
    expanded = File.expand_path(path.to_s)
    parent   = File.expand_path(releases_path)
    unless File.dirname(expanded) == parent && expanded != parent
      raise UnsafePath, "refusing to delete #{path.inspect}: not a direct child of #{releases_path}"
    end
    raise UnsafePath, "refusing to delete the live release #{path}" if current_target == expanded

    FileUtils.rm_rf(expanded)
    expanded
  end

  # Release directories on disk, newest first. Used to reconcile the disk with
  # the Release table (a directory with no row is still garbage worth reporting).
  def release_names
    Dir.children(releases_path).sort.reverse
  rescue Errno::ENOENT
    []
  end

  # ---- deploy lock ---------------------------------------------------------

  # Serialise deploys of one app. Two concurrent deploys would build into two
  # release directories and then race the `current` swap, so the loser's health
  # check would validate the winner's code.
  #
  # WHY flock and not a database flag: the lock is held by the open file
  # description, so the kernel drops it the instant the process dies. A
  # `deploying` column survives a SIGKILL'd worker and strands the app until
  # somebody notices and clears it by hand.
  def with_deploy_lock
    FileUtils.mkdir_p(root)
    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |f|
      unless f.flock(File::LOCK_EX | File::LOCK_NB)
        raise Locked, "another deploy of #{app.name} is already running (#{lock_path})"
      end

      f.truncate(0)
      f.write("#{Process.pid} #{Time.now.utc.iso8601}\n")
      f.flush
      begin
        yield
      ensure
        f.flock(File::LOCK_UN)
      end
    end
  end

  # Swaps `current` onto a new release, proves the site still answers, and puts
  # the previous release back when it does not.
  #
  # Both the health probe and the restart are injected callables: the caller owns
  # how an app is restarted (touch tmp/restart.txt today, `systemctl restart
  # ltvb-app@<fqdn>` once Passenger is gone) and this object only owns the order
  # of operations, which is the part that must not be improvised inline.
  class Promotion
    Result = Struct.new(:ok, :rolled_back, :detail, keyword_init: true) do
      def ok? = !!ok
      def rolled_back? = !!rolled_back
    end

    # health:  -> AppStatusChecker-shaped Hash { status:, code:, detail: }
    # restart: -> called after each swap, before polling
    def initialize(layout:, release_path:, previous_path: nil, health:, restart:,
                   logger: nil, tries: 6, delay: 2, sleeper: nil)
      @layout   = layout
      @release  = release_path
      @previous = previous_path
      @health   = health
      @restart  = restart
      @logger   = logger
      @tries    = tries
      @delay    = delay
      @sleeper  = sleeper || ->(seconds) { sleep seconds }
    end

    def call
      promote(@release)
      result = wait_for_health
      return Result.new(ok: true, rolled_back: false, detail: result[:detail]) if healthy?(result)

      failure = "#{result[:status]}: #{result[:detail]}"
      log "new release is not healthy (#{failure})\n"

      unless @previous
        # Nothing to fall back to (first deploy). Leaving `current` on the broken
        # release is still better than deleting it: the operator gets logs and a
        # directory to inspect instead of a missing DocumentRoot.
        return Result.new(ok: false, rolled_back: false,
                          detail: "#{failure}; no previous release to roll back to")
      end

      log "rolling back to #{@previous}\n"
      promote(@previous)
      back = wait_for_health
      detail = if healthy?(back)
        "#{failure}; rolled back to the previous release"
      else
        "#{failure}; rollback to #{@previous} is ALSO unhealthy (#{back[:status]}: #{back[:detail]})"
      end
      Result.new(ok: false, rolled_back: true, detail: detail)
    end

    private

    def promote(path)
      @layout.swap!(path)
      log "current -> #{path}\n"
      @restart.call
    end

    # Restarted app servers cold-spawn on the first request (Passenger) or take a
    # moment to bind (puma), so a single probe would fail every healthy deploy.
    def wait_for_health
      result = nil
      @tries.times do |i|
        result = @health.call || {}
        log "  health #{i + 1}/#{@tries}: #{result[:status]} (HTTP #{result[:code]})\n"
        return result if healthy?(result)

        @sleeper.call(@delay) unless i == @tries - 1
      end
      result || {}
    end

    def healthy?(result)
      AppStatusChecker::HEALTHY.include?(result[:status])
    end

    def log(message)
      @logger&.call(message)
    end
  end
end
