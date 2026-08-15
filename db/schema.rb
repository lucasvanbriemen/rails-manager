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

ActiveRecord::Schema[8.0].define(version: 2026_08_15_180003) do
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
    t.string "webhook_token"
    t.text "webhook_secret"
    t.boolean "auto_deploy", default: false, null: false
    t.string "webhook_branch"
    t.string "php_version"
    t.string "runtime_user"
    t.string "doc_root_suffix", default: "public", null: false
    t.string "health_check_path", default: "/", null: false
    t.string "ip_allowlist"
    t.boolean "hsts", default: false, null: false
    t.boolean "serves_http", default: true, null: false
    t.datetime "archived_at"
    t.string "cable_path"
    t.integer "cable_port"
    t.string "xaccel_path"
    t.boolean "redirect_http", default: true, null: false
    t.boolean "default_server", default: false, null: false
    t.boolean "apex_confirmed", default: false, null: false
    t.string "deploy_strategy", default: "in_place", null: false
    t.index ["archived_at"], name: "index_apps_on_archived_at"
    t.index ["ingest_token"], name: "index_apps_on_ingest_token", unique: true
    t.index ["subdomain", "domain"], name: "index_apps_on_subdomain_and_domain", unique: true
    t.index ["webhook_token"], name: "index_apps_on_webhook_token", unique: true
  end

  create_table "backups", force: :cascade do |t|
    t.string "path", null: false
    t.string "status", default: "running", null: false
    t.string "host"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.bigint "size_bytes"
    t.integer "item_count"
    t.json "manifest", default: [], null: false
    t.json "excluded", default: [], null: false
    t.text "log"
    t.text "error"
    t.string "verify_status", default: "pending", null: false
    t.datetime "verified_at"
    t.string "verify_database"
    t.integer "verify_tables"
    t.bigint "verify_rows"
    t.text "verify_detail"
    t.datetime "pruned_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["path"], name: "index_backups_on_path", unique: true
    t.index ["started_at"], name: "index_backups_on_started_at"
    t.index ["status", "started_at"], name: "index_backups_on_status_and_started_at"
    t.index ["verify_status", "verified_at"], name: "index_backups_on_verify_status_and_verified_at"
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
    t.string "kind", default: "rails", null: false
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

  create_table "mail_aliases", force: :cascade do |t|
    t.integer "mail_domain_id", null: false
    t.string "local_part", null: false
    t.json "destinations", default: [], null: false
    t.boolean "enabled", default: true, null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["mail_domain_id", "local_part"], name: "index_mail_aliases_on_mail_domain_id_and_local_part", unique: true
    t.index ["mail_domain_id"], name: "index_mail_aliases_on_mail_domain_id"
  end

  create_table "mail_domains", force: :cascade do |t|
    t.string "name", null: false
    t.boolean "active", default: true, null: false
    t.boolean "local_delivery", default: true, null: false
    t.string "dkim_selector"
    t.string "catch_all", default: "reject", null: false
    t.string "catch_all_target"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_mail_domains_on_name", unique: true
  end

  create_table "mailboxes", force: :cascade do |t|
    t.integer "mail_domain_id", null: false
    t.string "local_part", null: false
    t.text "password_digest"
    t.datetime "password_set_at"
    t.bigint "quota_bytes"
    t.boolean "active", default: true, null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["mail_domain_id", "local_part"], name: "index_mailboxes_on_mail_domain_id_and_local_part", unique: true
    t.index ["mail_domain_id"], name: "index_mailboxes_on_mail_domain_id"
  end

  create_table "process_services", force: :cascade do |t|
    t.integer "app_id"
    t.string "name", null: false
    t.string "kind", default: "generic", null: false
    t.json "argv", default: [], null: false
    t.string "user", null: false
    t.string "working_directory", null: false
    t.json "environment", default: {}, null: false
    t.boolean "autostart", default: true, null: false
    t.boolean "managed", default: true, null: false
    t.boolean "enabled", default: true, null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_process_services_on_app_id"
    t.index ["name"], name: "index_process_services_on_name", unique: true
  end

  create_table "releases", force: :cascade do |t|
    t.integer "app_id", null: false
    t.integer "deployment_id"
    t.string "path", null: false
    t.string "git_ref"
    t.string "git_branch"
    t.string "status", default: "building", null: false
    t.datetime "deployed_at"
    t.datetime "superseded_at"
    t.integer "build_duration_ms"
    t.bigint "size_bytes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "created_at"], name: "index_releases_on_app_id_and_created_at"
    t.index ["app_id", "path"], name: "index_releases_on_app_id_and_path", unique: true
    t.index ["app_id", "status"], name: "index_releases_on_app_id_and_status"
    t.index ["app_id"], name: "index_releases_on_app_id"
  end

  create_table "scheduled_jobs", force: :cascade do |t|
    t.integer "app_id"
    t.string "name", null: false
    t.string "user", null: false
    t.string "cron_schedule", null: false
    t.json "argv", default: [], null: false
    t.string "working_directory"
    t.json "environment", default: {}, null: false
    t.boolean "discard_output", default: false, null: false
    t.boolean "managed", default: true, null: false
    t.boolean "enabled", default: true, null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_scheduled_jobs_on_app_id"
    t.index ["managed"], name: "index_scheduled_jobs_on_managed"
    t.index ["name"], name: "index_scheduled_jobs_on_name", unique: true
  end

  create_table "webhook_deliveries", force: :cascade do |t|
    t.integer "app_id", null: false
    t.string "provider", default: "github", null: false
    t.string "event"
    t.string "external_id"
    t.string "status", default: "received", null: false
    t.string "ref"
    t.string "commit_sha"
    t.string "pusher"
    t.text "message"
    t.integer "deployment_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_webhook_deliveries_on_app_id"
    t.index ["created_at"], name: "index_webhook_deliveries_on_created_at"
    t.index ["deployment_id"], name: "index_webhook_deliveries_on_deployment_id"
    t.index ["provider", "external_id"], name: "index_webhook_deliveries_on_provider_and_external_id", unique: true
  end

  add_foreign_key "console_sessions", "apps"
  add_foreign_key "deployments", "apps"
  add_foreign_key "exception_events", "exception_groups"
  add_foreign_key "exception_groups", "apps"
  add_foreign_key "mail_aliases", "mail_domains"
  add_foreign_key "mailboxes", "mail_domains"
  add_foreign_key "process_services", "apps"
  add_foreign_key "releases", "apps"
  add_foreign_key "scheduled_jobs", "apps"
  add_foreign_key "webhook_deliveries", "apps"
  add_foreign_key "webhook_deliveries", "deployments"
end
