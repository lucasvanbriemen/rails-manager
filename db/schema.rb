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

ActiveRecord::Schema[8.0].define(version: 2026_07_11_100003) do
  create_table "apps", force: :cascade do |t|
    t.string "name", null: false
    t.string "subdomain"
    t.string "domain"
    t.string "ruby_version", default: "3.3.8", null: false
    t.string "git_repo_url"
    t.string "git_branch", default: "main", null: false
    t.string "primary_db_kind", default: "sqlite", null: false
    t.text "notes"
    t.text "master_key"
    t.text "env_text"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "app_kind", default: "rails", null: false
    t.string "deploy_path"
    t.text "post_deploy_commands"
    t.string "ingest_token"
    t.index ["ingest_token"], name: "index_apps_on_ingest_token", unique: true
    t.index ["subdomain", "domain"], name: "index_apps_on_subdomain_and_domain", unique: true
  end

  create_table "console_sessions", force: :cascade do |t|
    t.integer "app_id", null: false
    t.string "status", default: "queued", null: false
    t.string "close_reason"
    t.text "output", default: "", null: false
    t.text "pending_input"
    t.boolean "close_requested", default: false, null: false
    t.datetime "started_at"
    t.datetime "closed_at"
    t.datetime "last_activity_at"
    t.datetime "heartbeat_at"
    t.string "started_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_console_sessions_on_app_id"
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

  create_table "exception_events", force: :cascade do |t|
    t.integer "exception_group_id", null: false
    t.text "message"
    t.text "backtrace"
    t.text "context"
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.index ["exception_group_id"], name: "index_exception_events_on_exception_group_id"
  end

  create_table "exception_groups", force: :cascade do |t|
    t.integer "app_id", null: false
    t.string "fingerprint", null: false
    t.string "exception_class", null: false
    t.text "message"
    t.string "status", default: "open", null: false
    t.integer "events_count", default: 0, null: false
    t.datetime "first_seen_at"
    t.datetime "last_seen_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "fingerprint"], name: "index_exception_groups_on_app_id_and_fingerprint", unique: true
    t.index ["app_id", "status"], name: "index_exception_groups_on_app_id_and_status"
    t.index ["app_id"], name: "index_exception_groups_on_app_id"
  end

  add_foreign_key "console_sessions", "apps"
  add_foreign_key "deployments", "apps"
  add_foreign_key "exception_events", "exception_groups"
  add_foreign_key "exception_groups", "apps"
end
