# The only automatic database backup on this server today is Plesk's
# /opt/psa/bin/mysqldump.sh, fired once a day from /etc/cron.daily/50plesk-daily
# into /var/lib/psa/dumps (0750 psaadm:psaadm). It goes away with the licence on
# 2026-09-01, and the loss is invisible: nothing errors, nothing is logged, and
# the first symptom is a restore with nothing to restore from.
#
# One row per backup RUN. Three of these columns are the reason the table exists
# rather than a directory listing being enough:
#
#   * `excluded` records, per run, exactly which tables were left out and why.
#     gitub_gui is 18.6 GB and 18.25 of those are one table, so *some* run is
#     going to want to skip it — and a backup that quietly omits data is worse
#     than one that fails. The omission is a column, not a comment in a script.
#   * `verified_at` / `verify_status` record that a dump FROM THIS RUN was
#     restored into a scratch database and compared table-for-table and
#     row-for-row. A backup nobody has restored is not a backup; this is the
#     column that says so out loud on the dashboard.
#   * `pruned_at` keeps the row after retention deletes the directory, so the
#     history of what was taken (and what was verified) outlives the bytes.
class CreateBackups < ActiveRecord::Migration[8.0]
  def change
    create_table :backups do |t|
      # Absolute path of this run's directory, e.g.
      # /var/backups/ltvb/20260815T180000Z. Kept after pruning: "there WAS a
      # verified backup on the 3rd, and it is gone now" is a different and much
      # more useful statement than silence.
      t.string   :path, null: false

      # running | succeeded | partial | failed. `partial` is its own state on
      # purpose: a run that dumped every database but could not read one
      # webspace's uploads is neither a success nor a failure, and collapsing it
      # into either is how a half-backup gets trusted.
      t.string   :status, null: false, default: "running"

      # Which host the files are on. One box today, but a manifest that does not
      # say where it came from is a manifest you cannot act on later.
      t.string   :host

      t.datetime :started_at
      t.datetime :finished_at

      t.bigint   :size_bytes
      t.integer  :item_count

      # The manifest: one entry per file with kind, source, byte size and
      # sha256. Stored on the row AND written as manifest.json inside the backup
      # directory — the copy on the row survives the directory being pruned or
      # the disk being lost, which is precisely when you need to know what a
      # backup contained.
      t.json     :manifest, null: false, default: []

      # [{ database:, table:, mode:, reason: }]. Never nil, never a summary
      # string: this is the machine-readable answer to "what is NOT in here".
      t.json     :excluded, null: false, default: []

      # The run's own log, appended step by step, so a failure at 3am is
      # readable without ssh.
      t.text     :log
      t.text     :error

      # ---- restore verification ----------------------------------------------
      # pending | passed | failed | skipped
      t.string   :verify_status, null: false, default: "pending"
      t.datetime :verified_at
      # Which database was actually restored, and the counts that were compared.
      # Named rather than assumed: the sample is chosen per run, and a "verified"
      # flag that does not say what it verified is not evidence.
      t.string   :verify_database
      t.integer  :verify_tables
      t.bigint   :verify_rows
      t.text     :verify_detail

      # Set when retention deletes the directory. The row stays.
      t.datetime :pruned_at

      t.timestamps
    end

    # Retention and the dashboard both ask "newest first, still on disk".
    add_index :backups, [ :started_at ]
    add_index :backups, [ :status, :started_at ]
    # "when was a backup last PROVEN restorable" is the one query that matters
    # most and the one that must never be a table scan behind a dashboard tile.
    add_index :backups, [ :verify_status, :verified_at ]
    # Two runs cannot share a directory: the stamp is second-resolution UTC, so
    # a duplicate means two runs raced, and the second would overwrite the
    # first's files while both rows claimed to hold them.
    add_index :backups, :path, unique: true
  end
end
