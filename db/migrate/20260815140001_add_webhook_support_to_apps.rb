class AddWebhookSupportToApps < ActiveRecord::Migration[8.0]
  def up
    # Public, per-app path segment. Knowing it is NOT enough to trigger a
    # deploy — the HMAC signature is the actual authentication.
    add_column :apps, :webhook_token, :string
    add_index  :apps, :webhook_token, unique: true

    # Shared secret configured on the GitHub side. Encrypted at rest like the
    # other stored credentials.
    add_column :apps, :webhook_secret, :text

    # Off by default: turning it on is a deliberate per-app decision, so
    # importing an app never silently arms auto-deploy.
    add_column :apps, :auto_deploy, :boolean, default: false, null: false

    # Which branch a push must touch. Blank means "the app's git_branch".
    add_column :apps, :webhook_branch, :string

    execute("SELECT id FROM apps").each do |row|
      execute ActiveRecord::Base.sanitize_sql(
        [ "UPDATE apps SET webhook_token = ? WHERE id = ?", SecureRandom.hex(24), row["id"] ]
      )
    end

    create_table :webhook_deliveries do |t|
      t.references :app, null: false, foreign_key: true
      t.string  :provider,    null: false, default: "github"
      t.string  :event                                   # push, ping, …
      t.string  :external_id                             # X-GitHub-Delivery
      t.string  :status,      null: false, default: "received"
      t.string  :ref                                     # refs/heads/main
      t.string  :commit_sha
      t.string  :pusher
      t.text    :message                                 # why it was ignored/failed
      t.references :deployment, foreign_key: true        # set when one was enqueued
      t.timestamps
    end

    # Dedupe key. GitHub retries deliveries; the unique index IS the guard
    # against a retry deploying twice.
    add_index :webhook_deliveries, [ :provider, :external_id ], unique: true
    add_index :webhook_deliveries, :created_at
  end

  def down
    drop_table :webhook_deliveries
    remove_column :apps, :webhook_token
    remove_column :apps, :webhook_secret
    remove_column :apps, :auto_deploy
    remove_column :apps, :webhook_branch
  end
end
