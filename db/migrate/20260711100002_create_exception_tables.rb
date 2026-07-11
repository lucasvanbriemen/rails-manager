class CreateExceptionTables < ActiveRecord::Migration[8.0]
  def change
    create_table :exception_groups do |t|
      t.references :app, null: false, foreign_key: true
      t.string  :fingerprint, null: false
      t.string  :exception_class, null: false
      t.text    :message
      t.string  :status, null: false, default: "open"
      t.integer :events_count, null: false, default: 0
      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.timestamps
      t.index [ :app_id, :fingerprint ], unique: true
      t.index [ :app_id, :status ]
    end

    create_table :exception_events do |t|
      t.references :exception_group, null: false, foreign_key: true
      t.text :message
      t.text :backtrace
      t.text :context
      t.datetime :occurred_at, null: false
      t.datetime :created_at, null: false
    end
  end
end
