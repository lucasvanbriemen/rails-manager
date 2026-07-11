class AddIngestTokenToApps < ActiveRecord::Migration[8.0]
  def up
    add_column :apps, :ingest_token, :string
    add_index :apps, :ingest_token, unique: true

    # Backfill existing apps so every record has a token from day one.
    execute("SELECT id FROM apps").each do |row|
      execute ActiveRecord::Base.sanitize_sql(
        [ "UPDATE apps SET ingest_token = ? WHERE id = ?", SecureRandom.hex(24), row["id"] ]
      )
    end
  end

  def down
    remove_column :apps, :ingest_token
  end
end
