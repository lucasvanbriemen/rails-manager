class CreateConsoleSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :console_sessions do |t|
      t.references :app, null: false, foreign_key: true
      t.string  :status, null: false, default: "queued"
      t.string  :close_reason
      t.text    :output, null: false, default: ""
      t.text    :pending_input
      t.boolean :close_requested, null: false, default: false
      t.datetime :started_at
      t.datetime :closed_at
      t.datetime :last_activity_at
      t.datetime :heartbeat_at
      t.string :started_by
      t.timestamps
    end
  end
end
