# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_06_22_190002) do
  create_table "apps", force: :cascade do |t|
    t.string "name", null: false
    t.string "subdomain", null: false
    t.string "domain", null: false
    t.string "ruby_version", default: "3.3.8", null: false
    t.string "source_mode", default: "git", null: false
    t.string "git_repo_url"
    t.string "git_branch", default: "main", null: false
    t.string "primary_db_kind", default: "sqlite", null: false
    t.text "notes"
    t.text "master_key"
    t.text "env_text"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["subdomain", "domain"], name: "index_apps_on_subdomain_and_domain", unique: true
  end

  create_table "deployments", force: :cascade do |t|
    t.integer "app_id", null: false
    t.string "kind", null: false
    t.string "status", default: "queued", null: false
    t.string "ref"
    t.text "log", default: "", null: false
    t.string "triggered_by"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_deployments_on_app_id"
  end

  add_foreign_key "deployments", "apps"
end
