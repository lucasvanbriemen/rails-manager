# Brings every app on server.ltvb.nl into the manager, from the Plesk export
# and the checkouts on disk. Idempotent by construction: it matches existing
# rows, writes only the fields it can prove, and never destroys anything.
#
#   rake manager:import DRY_RUN=1                 # show the plan, touch nothing
#   rake manager:import                           # apply it
#   rake manager:import EXPORT_DIR=/root/plesk-export DISK_LAYOUT=/tmp/layout.tsv
#   rake manager:import CRONTABS=/tmp/crontabs.txt        # the export has none
#   rake manager:import ALLOW_DEGRADED_PROBE=1            # last resort, see below
#
# The export is 0700 root-only and the webspaces are 0750 owner:psaserv, so a
# run as `ltvb` sees neither. Either run it as root, or (as root, once) copy the
# export somewhere readable and capture the checkout probe to a TSV, then run as
# `ltvb` with EXPORT_DIR and DISK_LAYOUT pointing at the copies. Running the
# manager's own rake as root would leave root-owned SQLite journals behind.
#
# A run that cannot read the checkouts is REFUSED rather than applied. It is not
# a degraded-but-usable answer: derive_kind's fallback is "static", so a probe
# that read nothing turns every Rails and Laravel app into a static site and the
# nginx config rendered from it has no app server and no PHP in it.

# Helpers live in a module rather than bare `def`s in the rake namespace, which
# would define them on Object -- `save` and `report` are not names to give away.
module ManagerImport
  # Raised instead of writing when the checkout probe could not read the disk.
  # See run: the plan is still printed, it just is not applied.
  class DegradedProbe < StandardError; end

  # Fields that describe how the *server* is configured -- they come from
  # Apache's vhosts, Plesk's records and git, none of which need the checkout to
  # be readable. Safe to refresh on every run.
  #
  # Deliberately absent:
  #   name             the existing rows are hand-named ("All in one"); the
  #                    import would rewrite them all to bare hostnames.
  #   master_key,
  #   env_text         secrets. Filled when blank, never replaced -- the stored
  #                    copy may be newer than the vhost's.
  #   auto_deploy      set false on create, then left alone. Disarming an app
  #                    the operator armed on purpose is not the import's call.
  #   archived_at      set once, when a directory is first seen abandoned. The
  #                    timestamp records when we noticed; re-running must not
  #                    keep moving it forward.
  #   ingest_token,
  #   webhook_token    generated per row, never derived from the server.
  #   notes            partly the operator's; see merged_notes.
  SERVER_FACTS = %i[
    subdomain domain runtime_user doc_root_suffix serves_http deploy_path
    ip_allowlist hsts git_repo_url git_branch post_deploy_commands
  ].freeze

  # Fields that describe what the *code* is, and therefore come from the disk
  # probe. The webspaces are 0750 owner:psaserv, so a run that cannot read them
  # gets no markers at all -- and ServerInventory.derive_kind's floor is
  # "static". Refreshing these from such a run rewrites every Rails and Laravel
  # app on the host to a static site, which then renders an nginx config with no
  # app server and no PHP: 22 hostnames serving directory listings, from an
  # import that reported success.
  #
  # primary_db_kind is in the list because it is derived from app_kind, not from
  # the server: refreshing it from an app_kind we did not trust enough to write
  # would launder the same guess back into the record.
  PROBE_DERIVED = %i[app_kind ruby_version php_version primary_db_kind].freeze

  REFRESHABLE = (SERVER_FACTS + PROBE_DERIVED).freeze

  # Everything below this line in an App's notes belongs to the import and is
  # rewritten each run; everything above it is whoever typed it.
  NOTES_MARKER = "--- from the Plesk import (rewritten on every run) ---".freeze

  Result = Struct.new(:action, :entry, :app, :details)

  module_function

  def run(export_dir:, dry_run:, allow_degraded: false)
    inventory = ServerInventory.new(
      export_dir: export_dir,
      disk: disk,
      crontabs: crontabs,
      # Only *live* checkouts are claimed. Archived rows must keep flowing
      # through the inventory or a re-import would stop reporting them, and the
      # abandoned directories would silently vanish from the migration's view
      # the moment they were first recorded.
      claimed_paths: App.where(archived_at: nil).where.not(deploy_path: [ nil, "" ]).pluck(:deploy_path)
    )

    # A run whose probe saw nothing is reported in full and then refused.
    # Reported, because the operator has to see *which* checkouts were invisible
    # and why; refused, because a probe that read nothing cannot tell a healthy
    # server from a Rails app that has been deleted, and the import writing its
    # guess is how good records get destroyed. ALLOW_DEGRADED_PROBE=1 downgrades
    # the refusal to a warning -- refreshable_changes still protects the probed
    # fields on rows that already exist.
    degraded = inventory.entries.select(&:probe_failed?)
    refused  = degraded.any? && !allow_degraded

    existing = App.all.index_by { |app| ServerInventory.match_key_for(app) }
    results  = inventory.entries.map do |entry|
      apply(entry, existing[entry.match_key], dry_run: dry_run || refused)
    end

    report(inventory, results, dry_run: dry_run, refused: refused)

    raise DegradedProbe, degraded_message(degraded) if refused
  end

  # Told apart from "the export is missing a file": this one means the manager
  # is running as the wrong user, and the fix is a flag, not a repair.
  def degraded_message(degraded)
    <<~MSG.strip
      REFUSED: the checkout probe could not read #{degraded.size} of the apps it classifies
      (#{degraded.first(5).map(&:name).join(', ')}#{'...' if degraded.size > 5}).

      Nothing was written. Every kind derived from an empty probe is "static", so applying
      this run would rewrite those apps' app_kind, ruby_version and php_version to a guess.

      The webspaces are 0750 owner:psaserv. Either run as root, or (as root, once) capture
      the probe and re-run as ltvb with DISK_LAYOUT=<file>. ALLOW_DEGRADED_PROBE=1 applies
      the run anyway; existing rows keep their probed fields either way.
    MSG
  end

  # Creates or updates one row.
  def apply(entry, app, dry_run:)
    app ||= App.new
    changes = refreshable_changes(entry, app)

    if app.new_record?
      changes[:name]        = entry.attributes[:name]
      changes[:auto_deploy] = false
    end
    changes[:archived_at] = Time.current if entry.archived? && app.archived_at.blank?

    # The single most valuable thing this import rescues: login.ltvb.nl has no
    # config/master.key on disk, so Apache's `SetEnv RAILS_MASTER_KEY` is the
    # only copy of its key. Once Passenger and that vhost are gone, so is it.
    if entry.attributes[:master_key].present? && app.master_key.blank?
      changes[:master_key] = entry.attributes[:master_key]
    end
    merged = merged_env(app.env_text, entry.attributes[:env_text])
    changes[:env_text] = merged unless merged == app.env_text
    notes = merged_notes(app.notes, entry.attributes[:notes])
    changes[:notes] = notes unless notes == app.notes

    action = if app.new_record? then :create
    elsif changes.any?          then :update
    else                             :unchanged
    end
    return Result.new(action, entry, app, changes) if dry_run || action == :unchanged

    app.assign_attributes(changes)
    return Result.new(action, entry, app, changes) if save(app, entry)

    Result.new(:failed, entry, app, app.errors.full_messages)
  end

  # A degraded probe never overwrites what an earlier, working run established.
  # A brand-new row has nothing to protect and is still created with the probed
  # fields -- leaving a live site untracked is worse than recording it with a
  # weak kind, and the report flags it either way.
  def refreshable_changes(entry, app)
    fields = entry.probe_failed? && app.persisted? ? SERVER_FACTS : REFRESHABLE

    fields.each_with_object({}) do |field, changes|
      value = entry.attributes[field]
      changes[field] = value unless app.read_attribute(field) == value
    end
  end

  # An apex site (ltvb.nl, lucasvanbriemen.nl, ...) has no subdomain, and App
  # requires one for anything it serves. Recording the row anyway is safe:
  # App#undeployable_reason independently reports "missing subdomain or domain"
  # and DeployRunner refuses to touch the filesystem for such a row -- whereas
  # leaving six live sites untracked is precisely the failure this migration
  # cannot afford. A row failing for any *other* reason is a real defect and is
  # left unsaved so the report shows it.
  def save(app, entry)
    return true if app.save
    return false unless entry.apex? && (app.errors.attribute_names - %i[subdomain]).empty?

    app.save(validate: false)
  end

  # Apache SetEnv vars are added to env_text, never allowed to overwrite it: a
  # var already present there is the operator's and wins.
  def merged_env(current, incoming)
    return current if incoming.blank?

    have = current.to_s.lines.map { |line| line.split("=", 2).first.to_s.strip }
    additions = incoming.lines.map(&:chomp).reject { |line| have.include?(line.split("=", 2).first.to_s.strip) }
    return current if additions.empty?

    [ current.presence, *additions ].compact.join("\n")
  end

  # Notes are half derived and half human. Replacing the derived half in place
  # keeps a re-import accurate without eating what an operator wrote above it.
  def merged_notes(current, incoming)
    operator = current.to_s.split(NOTES_MARKER, 2).first.to_s.rstrip
    [ operator.presence, NOTES_MARKER, incoming ].compact.join("\n")
  end

  # LiveDisk stats the checkouts directly. DISK_LAYOUT replays a probe captured
  # earlier as root, for runs that cannot read the webspaces.
  def disk
    layout = ENV["DISK_LAYOUT"]
    layout.present? ? ServerInventory::MarkerDisk.new(File.read(layout)) : ServerInventory::LiveDisk.new
  end

  # The export has no crontabs.txt, so until the capture script grows one this
  # is the only way the three cron-only apps reach the import at all. Nil rather
  # than "" when unset, so ServerInventory still warns about the missing file.
  def crontabs
    path = ENV["CRONTABS"]
    File.read(path) if path.present?
  end

  # ---- report ---------------------------------------------------------------

  def report(inventory, results, dry_run:, refused:)
    entries = inventory.entries

    puts
    puts headline(dry_run: dry_run, refused: refused)
    puts
    printf("%-9s %-40s %-8s %-9s %-38s %s\n", "ACTION", "APP", "KIND", "BRANCH", "GIT REMOTE", "RUNS AS")
    puts "-" * 130
    results.each do |result|
      attributes = result.entry.attributes
      printf("%-9s %-40s %-8s %-9s %-38s %s\n",
             result.action.to_s.upcase, result.entry.name, result.entry.app_kind,
             attributes[:git_branch], truncate(attributes[:git_repo_url], 38),
             attributes[:runtime_user] || "-")
    end
    puts
    puts "#{entries.size} apps: " +
         results.group_by(&:action).map { |action, rows| "#{rows.size} #{action}" }.join(", ")

    unreachable = entries.select { |entry| entry.remote_status.present? && entry.remote_status != "REACHABLE" }
    section "NO REACHABLE GIT REMOTE -- the checkout and the bundle are the only copies",
            unreachable.map { |entry| "#{entry.name}: #{entry.remote_status}\n#{indent(entry.flags)}" }

    section "BRANCH CORRECTED FROM THE CHECKOUT (Plesk's record was stale)",
            entries.select { |entry| diverged?(entry) }
                   .map { |entry| "#{entry.name}: plesk=#{entry.plesk_branch} disk=#{entry.disk_branch} " \
                                  "-> imported #{entry.attributes[:git_branch]}" }

    section "SECRETS RESCUED FROM APACHE",
            entries.select { |entry| entry.attributes[:master_key].present? }
                   .map { |entry| "#{entry.name}: RAILS_MASTER_KEY captured from vhost.conf SetEnv" }

    section "ARCHIVED (abandoned directories -- recorded so they are not rediscovered later)",
            entries.select(&:archived?).map { |entry| "#{entry.name} -> #{entry.attributes[:deploy_path]}" }

    section "RECORDED BUT NOT DEPLOYABLE (apex hosts: App cannot express a blank subdomain yet)",
            entries.select(&:apex?).map { |entry| "#{entry.name} (docroot #{entry.document_root})" }

    section "ALL FLAGS",
            entries.reject { |entry| entry.flags.empty? }
                   .map { |entry| "#{entry.name}\n#{indent(entry.flags)}" }

    section "COULD NOT SAVE",
            results.select { |result| result.action == :failed }
                   .map { |result| "#{result.entry.name}: #{Array(result.details).join('; ')}" }

    section "DEGRADED PROBE -- these checkouts were not readable, so their kind is a guess",
            entries.select(&:probe_failed?)
                   .map { |entry| "#{entry.name} (would be imported as #{entry.app_kind})" }

    section "ACME", acme_lines(inventory)

    section "SCHEDULED JOBS NOT YET ADOPTED (crontab lines no scheduled_jobs row describes)",
            unadopted_jobs(inventory).map { |job| "#{job[:user]}: #{job[:raw]}" }

    section "CRONTAB LINES THAT COULD NOT BE MODELLED (a shell construct argv cannot hold)",
            inventory.unmodellable_jobs.map { |job| "#{job[:user]}: #{job[:raw]}" }

    section "EXPORT WARNINGS", inventory.warnings
  end

  def headline(dry_run:, refused:)
    return "REFUSED -- the checkout probe was degraded; nothing was written" if refused

    dry_run ? "DRY RUN -- nothing was written" : "IMPORT applied"
  end

  # Cron is reconciled, never imported: the nine real lines are adopted
  # read-only by the ScheduledJob migration, and this section exists so a line
  # added to a crontab afterwards surfaces here instead of staying invisible
  # until whatever it does stops happening.
  def unadopted_jobs(inventory)
    adopted = ScheduledJob.all.map(&:signature)

    inventory.scheduled_jobs.reject do |job|
      signature = ScheduledJob.signature_for(user: job[:user], cron_schedule: job[:cron_schedule],
                                             argv: job[:argv])
      adopted.include?(signature)
    end
  end

  # The webroot every certificate on this host actually renews through, next to
  # the one the nginx renderer writes into each vhost. They do not currently
  # agree, and a mismatch means the challenge file certbot writes is not the one
  # nginx serves -- which fails at renewal time, weeks after the cutover, on a
  # site that was working.
  def acme_lines(inventory)
    observed = inventory.acme_webroot
    rendered = NginxConfig::ACME_WEBROOT if defined?(NginxConfig::ACME_WEBROOT)
    lines    = [ "certbot renews through: #{observed}" ]
    lines << "nginx serves challenges from: #{rendered}" if rendered
    if rendered && rendered != observed
      lines << "MISMATCH: point one at the other, or renewal breaks the first time a cert " \
               "comes up for renewal after Apache is gone"
    end
    lines
  end

  def diverged?(entry)
    entry.plesk_branch.present? && entry.disk_branch.present? && entry.plesk_branch != entry.disk_branch
  end

  def section(title, lines)
    return if lines.blank?

    puts
    puts title
    puts "-" * title.length
    lines.each { |line| puts "  #{line}" }
  end

  def indent(lines) = Array(lines).map { |line| "    - #{line}" }.join("\n")

  def truncate(text, width)
    text = text.to_s
    text.length > width ? "#{text[0, width - 1]}~" : text
  end
end

namespace :manager do
  desc "Import every app on the server from the Plesk export (DRY_RUN=1 to preview)"
  task import: :environment do
    export_dir = ENV.fetch("EXPORT_DIR", "/root/plesk-export")
    abort "EXPORT_DIR #{export_dir} is not readable" unless File.readable?(export_dir)

    begin
      ManagerImport.run(export_dir: export_dir,
                        dry_run: ENV["DRY_RUN"].present?,
                        allow_degraded: ENV["ALLOW_DEGRADED_PROBE"].present?)
    rescue ManagerImport::DegradedProbe => e
      # abort, not raise: the report above is the useful output and a backtrace
      # would bury it. Exit status is still non-zero, so a wrapper notices.
      abort "\n#{e.message}"
    end
  end
end
