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

ActiveRecord::Schema[8.1].define(version: 2026_07_04_100000) do
  create_table "accounts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "fakeid", null: false
    t.datetime "last_crawled_at"
    t.string "nickname", null: false
    t.string "round_head_img"
    t.integer "status", default: 0
    t.integer "total_articles", default: 0
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.index ["fakeid"], name: "index_accounts_on_fakeid", unique: true
    t.index ["status"], name: "index_accounts_on_status"
    t.index ["type"], name: "index_accounts_on_type"
  end

  create_table "articles", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "author"
    t.text "content_html"
    t.text "content_markdown"
    t.string "cover_url"
    t.integer "crawl_task_id"
    t.datetime "created_at", null: false
    t.text "digest"
    t.datetime "published_at"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["account_id"], name: "index_articles_on_account_id"
    t.index ["crawl_task_id"], name: "index_articles_on_crawl_task_id"
    t.index ["published_at"], name: "index_articles_on_published_at"
    t.index ["url"], name: "index_articles_on_url", unique: true
  end

  create_table "crawl_logs", force: :cascade do |t|
    t.text "context"
    t.integer "crawl_task_id", null: false
    t.datetime "created_at", null: false
    t.string "level", null: false
    t.datetime "logged_at"
    t.text "message"
    t.datetime "updated_at", null: false
    t.index ["crawl_task_id"], name: "index_crawl_logs_on_crawl_task_id"
    t.index ["level"], name: "index_crawl_logs_on_level"
    t.index ["logged_at"], name: "index_crawl_logs_on_logged_at"
  end

  create_table "crawl_tasks", force: :cascade do |t|
    t.integer "account_concurrency"
    t.json "account_ids"
    t.integer "article_concurrency"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "error_count", default: 0
    t.text "error_message"
    t.integer "progress", default: 0
    t.datetime "started_at"
    t.integer "status", default: 0
    t.integer "total"
    t.datetime "updated_at", null: false
    t.index ["status"], name: "index_crawl_tasks_on_status"
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
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.datetime "email_confirmed_at"
    t.datetime "last_login_at"
    t.string "name"
    t.string "password_digest", null: false
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.index ["role"], name: "index_users_on_role"
  end

  add_foreign_key "articles", "accounts"
  add_foreign_key "articles", "crawl_tasks"
  add_foreign_key "crawl_logs", "crawl_tasks"
  add_foreign_key "sessions", "users"
end
