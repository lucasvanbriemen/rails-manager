# One row per built release directory under <app_path>/releases/. Today a deploy
# mutates the directory Apache is serving (git reset --hard, bundle install,
# assets:precompile, db:prepare all run in-place), so any failure between two
# steps leaves a half-built LIVE site. Releases give us somewhere to build that
# nobody is serving, and — because the rows outlive the build — something to roll
# back TO when the freshly promoted release fails its health check.
class CreateReleases < ActiveRecord::Migration[8.0]
  def change
    create_table :releases do |t|
      t.references :app, null: false, foreign_key: true

      # Deliberately NOT a foreign key. Both apps.deployments and apps.releases
      # are dependent: :destroy, and Active Record has no defined order between
      # the two — a real FK would blow up whenever deployments happened to be
      # destroyed first. The column is a convenience link to the deploy log.
      t.integer :deployment_id

      # Absolute path of the release directory. Kept even after the directory is
      # pruned so the deploy history still shows what was built where.
      t.string :path, null: false

      t.string :git_ref     # full sha — the only thing that identifies the code
      t.string :git_branch

      t.string :status, null: false, default: "building"

      # deployed_at = the moment `current` was swapped onto this release.
      # superseded_at = the moment it was swapped off again. Both nil while
      # building, which is how a crashed build is told apart from a live one.
      t.datetime :deployed_at
      t.datetime :superseded_at

      # Build cost and footprint. Milliseconds because a hardlink-seeded rebuild
      # of an unchanged bundle finishes well under a second.
      t.integer :build_duration_ms
      t.bigint  :size_bytes

      t.timestamps
    end

    # The prune/rollback queries all filter by app and sort newest-first.
    add_index :releases, [ :app_id, :created_at ]
    add_index :releases, [ :app_id, :status ]
    # A release directory is named after a UTC timestamp, so a duplicate row for
    # one path means two deploys raced within the same second — the deploy lock
    # should prevent it, and the database is the backstop.
    add_index :releases, [ :app_id, :path ], unique: true
  end
end
