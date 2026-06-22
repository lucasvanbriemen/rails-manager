class CreateApps < ActiveRecord::Migration[8.0]
  def change
    create_table :apps do |t|
      t.string  :name,            null: false
      t.string  :subdomain,       null: false
      t.string  :domain,          null: false
      t.string  :ruby_version,    null: false, default: "3.3.8"
      t.string  :source_mode,     null: false, default: "git" # git | upload
      t.string  :git_repo_url
      t.string  :git_branch,      null: false, default: "main"
      t.string  :primary_db_kind, null: false, default: "sqlite" # sqlite | external
      t.text    :notes

      # Secrets, encrypted at rest via ActiveRecord encryption.
      t.text    :master_key       # config/master.key contents
      t.text    :env_text         # full .env file contents (KEY=VALUE lines)

      t.timestamps
    end

    add_index :apps, [ :subdomain, :domain ], unique: true
  end
end
