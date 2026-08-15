# The replacement for /etc/cron.daily/50plesk-daily, which is the only thing
# backing this server up today and dies with the Plesk licence on 2026-09-01.
#
#   rake backup:plan                  # print what a run would take, touch nothing
#   rake backup:run                   # take a backup, then prove it restores
#   rake backup:run SKIP_VERIFY=1     # ... and record it as verify_status=skipped
#   rake backup:verify                # re-prove the newest backup on disk
#   rake backup:verify ID=42          # ... or a specific one
#   rake backup:prune DRY_RUN=1       # show what retention would delete
#   rake backup:prune                 # apply it
#   rake backup:status                # last run, last VERIFIED run, exclusions
#
# All of it needs root: the webspaces are 0750 owner:psaserv, /etc/ltvb and the
# crontabs are root-only, and the MariaDB credentials live in a root-owned
# my.cnf on purpose. The clock behind it is deploy/ltvb-backup.timer — install
# it, or this file is a backup system nothing ever runs — and see
# BackupRunner::Delegated for the path the unprivileged manager will take once
# the agent has the verbs.
#
# WHY the nightly job verifies every time rather than weekly: verification is
# the only part of this that produces evidence, it costs one restore of the
# smallest database on the box, and a check that runs weekly is a check that has
# been broken for up to six days before anyone finds out.
namespace :backup do
  desc "Print the backup plan (databases, exclusions, files) without touching anything"
  task plan: :environment do
    runner = BackupRunner.new(**BackupTask.options)
    plan   = runner.plan

    puts
    puts "backup plan for #{plan.directory}"
    # Two lines because they answer two questions: what the plan NAMES (which is
    # what would be handed to root) and what this process would actually open.
    puts "credentials: #{plan.defaults_file} (preferred)"
    puts "             #{runner.resolved_defaults_file} would be used by this process" \
         "#{File.readable?(runner.resolved_defaults_file) ? '' : ' (NOT READABLE by it)'}"
    puts

    BackupTask.section "MARIADB (#{plan.databases.size})", plan.databases.map { |database|
      policy = plan.policies[database]
      kept   = BackupRunner::DELIBERATELY_KEPT.include?(database) ? "  [kept on purpose]" : ""
      "#{database}: #{policy.mode}#{policy.tables.any? ? " without #{policy.tables.join(', ')}" : ''}#{kept}"
    }

    BackupTask.section "EXCLUDED — NOT in the backup", plan.exclusions.map { |exclusion|
      "#{exclusion.target}: #{exclusion.reason}"
    }

    BackupTask.section "SQLITE (#{plan.sqlite.size}) — copied with `sqlite3 .backup`, never cp", plan.sqlite
    BackupTask.section "APP FILES (#{plan.app_files.size})", plan.app_files.map { |set|
      without = Array(set[:excludes]).any? ? "  (without #{Array(set[:excludes]).join(', ')})" : ""
      "#{set[:name]}: #{set[:entries].join(', ')}#{without}"
    }
    BackupTask.section "SYSTEM CONFIG (#{plan.system_paths.size})", plan.system_paths
    BackupTask.section "MISSING SYSTEM CONFIG — a run now would be PARTIAL",
                       BackupRunner::SYSTEM_PATHS - plan.system_paths
    # Everything the plan could not account for, including any checkout on disk
    # with no App row: a smaller manifest must never be the only symptom.
    BackupTask.section "PROBLEMS — a run now would be PARTIAL", runner.problems
    puts
  end

  desc "Take a backup and verify that one of its dumps restores (SKIP_VERIFY=1 to skip)"
  task run: :environment do
    BackupTask.warn_if_unprivileged

    backup = BackupRunner.new(**BackupTask.options, verify: ENV["SKIP_VERIFY"].blank?).call
    BackupTask.report(backup)

    # Non-zero exit so cron, a systemd timer or a wrapper notices. A PARTIAL run
    # is deliberately NOT a failure — it holds real dumps — but an unverified
    # one is, because "we took a backup and could not prove it restores" is the
    # single most important thing this job can tell anybody.
    abort "backup #{backup.status}" if backup.status == Backup::FAILED

    # Every outcome other than "passed" counts here, not just "failed": a
    # verification that was SKIPPED because no dump had any rows in it is
    # exactly as much evidence as one that failed, which is none.
    if ENV["SKIP_VERIFY"].blank? && !backup.verified?
      abort "backup taken but NOT proven to restore (#{backup.verify_status}): #{backup.verify_detail}"
    end
  end

  desc "Restore a backup's sample dump into a scratch database and compare it (ID=<id>)"
  task verify: :environment do
    BackupTask.warn_if_unprivileged

    backup = ENV["ID"].present? ? Backup.find(ENV["ID"]) : Backup.usable.on_disk.ordered.first
    abort "no backup to verify" if backup.nil?
    abort "#{backup.path} is not on disk any more" unless backup.on_disk?

    BackupRunner.for(backup, **BackupTask.options.except(:root)).verify!(database: ENV["DATABASE"].presence)
    backup.reload
    puts "#{backup.path}: verification #{backup.verify_status} — #{backup.verify_detail}"
    abort "verification failed" unless backup.verified?
  end

  desc "Delete backups retention no longer protects (DRY_RUN=1 to preview)"
  task prune: :environment do
    dry_run = ENV["DRY_RUN"].present?
    runner  = BackupRunner.new(**BackupTask.options)

    prunable = Backup.prunable
    kept = Backup.on_disk.ordered.to_a.select(&:on_disk?) - prunable
    puts
    puts "retention: #{Backup::RETENTION.map { |tier, count| "#{count} #{tier}" }.join(', ')}, " \
         "plus the newest run and the newest VERIFIED run"
    BackupTask.section "KEEPING (#{kept.size})", kept.map { |backup| BackupTask.line(backup) }
    BackupTask.section "ROWS WHOSE DIRECTORY IS ALREADY GONE — recorded as pruned, row kept",
                       Backup.ghosts.map { |backup| BackupTask.line(backup) }

    pruned = runner.prune!(dry_run: dry_run)
    BackupTask.section "#{dry_run ? 'WOULD DELETE' : 'DELETED'} (#{pruned.size})",
                       pruned.map { |backup| BackupTask.line(backup) }
    # Never deleted from here: the manager's own database is inside the backup,
    # so after a restore of it every newer directory is an orphan — and a sweep
    # would eat the newest backups first.
    BackupTask.section "ORPHAN DIRECTORIES — no row, NOT deleted; check and rm by hand",
                       runner.orphan_directories
    BackupTask.section "PROBLEMS", runner.problems
    puts
  end

  desc "When the last backup ran, and when one was last proven to restore"
  task status: :environment do
    latest   = Backup.ordered.first
    verified = Backup.last_verified

    puts
    puts latest ? "last run:      #{BackupTask.line(latest)}" : "last run:      NEVER — nothing has ever been backed up"
    puts verified ? "last verified: #{BackupTask.line(verified)}" : "last verified: NEVER — no backup has ever been proven to restore"
    puts "               #{Backup.verification_summary}"

    if latest && verified && latest.id != verified.id
      puts
      puts "the newest backup is NOT the one that was verified — #{latest.verify_status}: #{latest.verify_detail}"
    end

    BackupTask.section "EXCLUDED FROM THE LAST RUN", Array(latest&.exclusion_summary)
    BackupTask.section "PROBLEMS", latest&.error.to_s.lines.map(&:chomp)
    puts
  end
end

# Helpers in a module rather than bare `def`s in the rake namespace, which would
# define them on Object -- `line`, `report` and `options` are not names to give
# away. Same reason as ManagerImport in import.rake.
module BackupTask
  module_function

  def options
    { root: ENV.fetch("BACKUP_ROOT", BackupRunner::ROOT) }.tap do |opts|
      opts[:defaults_file] = ENV["MYSQL_DEFAULTS_FILE"] if ENV["MYSQL_DEFAULTS_FILE"].present?
    end
  end

  # Not an abort: a run as the wrong user still produces a real backup of
  # whatever it CAN read, and the run reports itself PARTIAL with the list. But
  # it must not look like a full one, so say it before the run rather than
  # leaving the operator to work it out from a short manifest.
  def warn_if_unprivileged
    return if Process.uid.zero?

    warn "WARNING: running as uid #{Process.uid}, not root. The webspaces are 0750, " \
         "/etc/ltvb and the crontabs are root-only, and the MariaDB credentials are in a " \
         "root-owned my.cnf — expect a PARTIAL backup. Run this from root's crontab."
  end

  def report(backup)
    puts
    puts "#{backup.path}: #{backup.status}, #{backup.item_count} files, #{number(backup.size_bytes)}"
    puts "verification: #{backup.verify_status}#{backup.verify_detail.present? ? " — #{backup.verify_detail}" : ''}"
    section "EXCLUDED — NOT in this backup", Array(backup.exclusion_summary)
    section "PROBLEMS", backup.error.to_s.lines.map(&:chomp)
    puts
  end

  def line(backup)
    stamp = backup.started_at&.utc&.iso8601 || "(no start time)"
    verified = backup.verified? ? "verified #{backup.verify_database} #{backup.verify_tables} tables/#{backup.verify_rows} rows" : backup.verify_status
    "#{stamp}  #{backup.status.ljust(9)} #{number(backup.size_bytes).rjust(10)}  #{verified}"
  end

  def number(bytes)
    return "-" if bytes.blank?

    ActiveSupport::NumberHelper.number_to_human_size(bytes)
  end

  def section(title, lines)
    lines = Array(lines).compact_blank
    return if lines.empty?

    puts
    puts title
    puts "-" * title.length
    lines.each { |line| puts "  #{line}" }
  end
end
