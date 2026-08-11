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

ActiveRecord::Schema[8.1].define(version: 2026_08_11_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "accounts", force: :cascade do |t|
    t.integer "activity_score", default: 0, null: false
    t.integer "articles_count", default: 0, null: false
    t.integer "articles_last_30_days", default: 0, null: false
    t.integer "articles_last_7_days", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "fakeid", null: false
    t.datetime "last_crawled_at"
    t.datetime "last_published_at"
    t.jsonb "metadata", default: {}
    t.string "nickname", null: false
    t.string "round_head_img"
    t.integer "status", default: 0
    t.integer "total_articles", default: 0
    t.string "twitter_screen_name"
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.index ["fakeid"], name: "index_accounts_on_fakeid", unique: true
    t.index ["metadata"], name: "index_accounts_on_metadata", using: :gin
    t.index ["status", "last_published_at"], name: "index_accounts_on_status_and_last_published_at"
    t.index ["status"], name: "index_accounts_on_status"
    t.index ["twitter_screen_name"], name: "index_accounts_on_twitter_screen_name"
    t.index ["type"], name: "index_accounts_on_type"
  end

  create_table "api_keys", force: :cascade do |t|
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "rate_limit", default: 100
    t.string "token"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["token"], name: "index_api_keys_on_token", unique: true
    t.index ["token_digest"], name: "index_api_keys_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_keys_on_user_id"
  end

  create_table "articles", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "author"
    t.text "content_html"
    t.text "content_markdown"
    t.string "cover_url"
    t.bigint "crawl_task_id"
    t.datetime "created_at", null: false
    t.text "digest"
    t.datetime "published_at"
    t.json "raw_data"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["account_id", "published_at"], name: "index_articles_on_account_id_and_published_at", order: { published_at: :desc }
    t.index ["crawl_task_id"], name: "index_articles_on_crawl_task_id"
    t.index ["published_at"], name: "index_articles_on_published_at"
    t.index ["url"], name: "index_articles_on_url", unique: true
  end

  create_table "crawl_logs", force: :cascade do |t|
    t.text "context"
    t.bigint "crawl_task_id", null: false
    t.datetime "created_at", null: false
    t.string "level", null: false
    t.datetime "logged_at"
    t.text "message"
    t.datetime "updated_at", null: false
    t.index ["crawl_task_id"], name: "index_crawl_logs_on_crawl_task_id"
    t.index ["level"], name: "index_crawl_logs_on_level"
    t.index ["logged_at"], name: "index_crawl_logs_on_logged_at"
  end

  create_table "crawl_task_accounts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "completed_at"
    t.bigint "crawl_task_id", null: false
    t.datetime "created_at", null: false
    t.text "error_message"
    t.datetime "started_at"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_crawl_task_accounts_on_account_id"
    t.index ["crawl_task_id", "account_id"], name: "idx_crawl_task_accounts_unique", unique: true
    t.index ["crawl_task_id", "status"], name: "idx_crawl_task_accounts_status"
    t.index ["crawl_task_id"], name: "index_crawl_task_accounts_on_crawl_task_id"
  end

  create_table "crawl_tasks", force: :cascade do |t|
    t.integer "account_concurrency"
    t.json "account_ids"
    t.integer "article_concurrency"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "error_count", default: 0
    t.text "error_message"
    t.json "platform_error_counts"
    t.integer "progress", default: 0
    t.integer "retry_count", default: 0, null: false
    t.datetime "started_at"
    t.integer "status", default: 0
    t.integer "total"
    t.datetime "updated_at", null: false
    t.index ["status"], name: "index_crawl_tasks_on_status"
  end

  create_table "group_accounts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.bigint "group_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_group_accounts_on_account_id"
    t.index ["group_id", "account_id"], name: "index_group_accounts_on_group_id_and_account_id", unique: true
    t.index ["group_id"], name: "index_group_accounts_on_group_id"
  end

  create_table "groups", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.string "ref_key", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "ref_key"], name: "index_groups_on_user_id_and_ref_key", unique: true
    t.index ["user_id"], name: "index_groups_on_user_id"
  end

  create_table "options", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "opt_key", null: false
    t.string "opt_value"
    t.datetime "updated_at", null: false
    t.index ["opt_key"], name: "index_options_on_opt_key", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "tag_accounts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.bigint "tag_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_tag_accounts_on_account_id"
    t.index ["tag_id", "account_id"], name: "index_tag_accounts_on_tag_id_and_account_id", unique: true
    t.index ["tag_id"], name: "index_tag_accounts_on_tag_id"
  end

  create_table "tags", force: :cascade do |t|
    t.string "color", default: "#6366f1"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "name_normalized", null: false
    t.integer "position", default: 0
    t.integer "tag_accounts_count", default: 0
    t.datetime "updated_at", null: false
    t.index ["name_normalized"], name: "index_tags_on_name_normalized", unique: true
    t.index ["position"], name: "index_tags_on_position"
  end

  create_table "user_tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "tag_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["tag_id"], name: "index_user_tags_on_tag_id"
    t.index ["user_id", "tag_id"], name: "index_user_tags_on_user_id_and_tag_id", unique: true
    t.index ["user_id"], name: "index_user_tags_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.datetime "email_confirmed_at"
    t.datetime "last_login_at"
    t.string "mp_id"
    t.string "name"
    t.string "password_digest"
    t.integer "role", default: 0, null: false
    t.json "settings", default: {}
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.index ["mp_id"], name: "index_users_on_mp_id", unique: true
    t.index ["role"], name: "index_users_on_role"
  end

  add_foreign_key "api_keys", "users"
  add_foreign_key "articles", "accounts"
  add_foreign_key "articles", "crawl_tasks"
  add_foreign_key "crawl_logs", "crawl_tasks"
  add_foreign_key "crawl_task_accounts", "accounts"
  add_foreign_key "crawl_task_accounts", "crawl_tasks"
  add_foreign_key "group_accounts", "accounts"
  add_foreign_key "group_accounts", "groups"
  add_foreign_key "groups", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "tag_accounts", "accounts"
  add_foreign_key "tag_accounts", "tags"
  add_foreign_key "user_tags", "tags"
  add_foreign_key "user_tags", "users"
end
