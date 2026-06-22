class CreateDeployments < ActiveRecord::Migration[8.0]
  def change
    create_table :deployments do |t|
      t.references :app, null: false, foreign_key: true
      t.string   :kind,   null: false              # create | deploy | restart | migrate_primary | destroy
      t.string   :status, null: false, default: "queued" # queued | running | succeeded | failed
      t.string   :ref                              # git sha/branch, or "upload"
      t.text     :log,    null: false, default: ""
      t.string   :triggered_by                     # admin email
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end
  end
end
