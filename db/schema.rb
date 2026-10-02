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

ActiveRecord::Schema[8.0].define(version: 2026_10_02_170000) do
  create_table "apps", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
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

  create_table "backups", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "path", null: false
    t.string "status", default: "running", null: false
    t.string "host"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.bigint "size_bytes"
    t.integer "item_count"
    t.text "manifest", size: :long, default: "[]", null: false, collation: "utf8mb4_bin"
    t.text "excluded", size: :long, default: "[]", null: false, collation: "utf8mb4_bin"
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
    t.check_constraint "json_valid(`excluded`)", name: "excluded"
    t.check_constraint "json_valid(`manifest`)", name: "manifest"
  end

  create_table "console_sessions", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "app_id", null: false
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

  create_table "deployments", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "app_id", null: false
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

  create_table "exception_events", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "exception_group_id", null: false
    t.text "message"
    t.text "backtrace"
    t.text "context"
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.index ["exception_group_id"], name: "index_exception_events_on_exception_group_id"
  end

  create_table "exception_groups", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "app_id", null: false
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

  create_table "mail_aliases", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "mail_domain_id", null: false
    t.string "local_part", null: false
    t.text "destinations", size: :long, default: "[]", null: false, collation: "utf8mb4_bin"
    t.boolean "enabled", default: true, null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["mail_domain_id", "local_part"], name: "index_mail_aliases_on_mail_domain_id_and_local_part", unique: true
    t.index ["mail_domain_id"], name: "index_mail_aliases_on_mail_domain_id"
    t.check_constraint "json_valid(`destinations`)", name: "destinations"
  end

  create_table "mail_domains", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
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

  create_table "mailboxes", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "mail_domain_id", null: false
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

  create_table "process_services", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "app_id"
    t.string "name", null: false
    t.string "kind", default: "generic", null: false
    t.text "argv", size: :long, default: "[]", null: false, collation: "utf8mb4_bin"
    t.string "user", null: false
    t.string "working_directory", null: false
    t.text "environment", size: :long, default: "{}", null: false, collation: "utf8mb4_bin"
    t.boolean "autostart", default: true, null: false
    t.boolean "managed", default: true, null: false
    t.boolean "enabled", default: true, null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_process_services_on_app_id"
    t.index ["name"], name: "index_process_services_on_name", unique: true
    t.check_constraint "json_valid(`argv`)", name: "argv"
    t.check_constraint "json_valid(`environment`)", name: "environment"
  end

  create_table "releases", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.bigint "deployment_id"
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

  create_table "scheduled_jobs", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "app_id"
    t.string "name", null: false
    t.string "user", null: false
    t.string "cron_schedule", null: false
    t.text "argv", size: :long, default: "[]", null: false, collation: "utf8mb4_bin"
    t.string "working_directory"
    t.text "environment", size: :long, default: "{}", null: false, collation: "utf8mb4_bin"
    t.boolean "discard_output", default: false, null: false
    t.boolean "managed", default: true, null: false
    t.boolean "enabled", default: true, null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_scheduled_jobs_on_app_id"
    t.index ["managed"], name: "index_scheduled_jobs_on_managed"
    t.index ["name"], name: "index_scheduled_jobs_on_name", unique: true
    t.check_constraint "json_valid(`argv`)", name: "argv"
    t.check_constraint "json_valid(`environment`)", name: "environment"
  end

  create_table "solid_cable_messages", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.binary "channel", limit: 1024, null: false
    t.binary "payload", size: :long, null: false
    t.datetime "created_at", null: false
    t.bigint "channel_hash", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_cache_entries", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.binary "key", limit: 1024, null: false
    t.binary "value", size: :long, null: false
    t.datetime "created_at", null: false
    t.bigint "key_hash", null: false
    t.integer "byte_size", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_blocked_executions", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "webhook_deliveries", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.string "provider", default: "github", null: false
    t.string "event"
    t.string "external_id"
    t.string "status", default: "received", null: false
    t.string "ref"
    t.string "commit_sha"
    t.string "pusher"
    t.text "message"
    t.bigint "deployment_id"
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
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "webhook_deliveries", "apps"
  add_foreign_key "webhook_deliveries", "deployments"
end
