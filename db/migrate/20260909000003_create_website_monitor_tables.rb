# The consolidated website-monitor schema, built directly on the Account
# ecosystem (no prototype tables — the earlier monitored_websites /
# website_monitor_runs / monitor_sources history was collapsed into this one
# migration before release):
#
#   - MonitorPage belongs to a WebsiteAccount (STI Account). A page IS the
#     information source (news index, changelog, ...), discovered from
#     sitemap.xml by WebsiteCrawler::Discovery.
#   - MonitorPageVersion snapshots one capture of a page's content;
#     MonitorPage#current_version_id points at its latest version (kept
#     plain bigint + index, not a FK, so the pointer is assigned only after
#     the version row exists).
#   - MonitorChange records one detected content diff, linked to the
#     CrawlTask that found it and to the account whose page changed.
class CreateWebsiteMonitorTables < ActiveRecord::Migration[8.1]
  def change
    create_table :monitor_pages do |t|
      t.references :account, null: false, foreign_key: true
      t.bigint :current_version_id
      t.string :url, null: false
      t.string :title
      t.string :page_type
      t.float :confidence
      t.string :discovered_via
      t.boolean :active, null: false, default: true
      t.string :last_status
      t.text :last_error
      t.string :fetched_via
      t.integer :error_count, null: false, default: 0
      t.integer :versions_count, null: false, default: 0
      t.datetime :last_checked_at
      t.datetime :last_changed_at
      t.datetime :sitemap_lastmod

      t.timestamps
    end
    # references build per-column indexes automatically; only composite /
    # extra lookup indexes are declared here.
    add_index :monitor_pages, [:account_id, :url], unique: true,
              name: "index_monitor_pages_on_account_and_url"
    add_index :monitor_pages, :current_version_id
    add_index :monitor_pages, :active

    create_table :monitor_page_versions do |t|
      t.references :monitor_page, null: false, foreign_key: true
      t.string :content_hash, null: false
      t.string :title
      t.text :content
      t.datetime :captured_at, null: false
      t.string :fetched_via
      t.integer :http_status
      t.integer :content_length, null: false, default: 0

      t.timestamps
    end
    add_index :monitor_page_versions, [:monitor_page_id, :created_at],
              name: "index_monitor_page_versions_on_page_and_created_at"
    add_index :monitor_page_versions, [:monitor_page_id, :content_hash],
              name: "index_monitor_page_versions_on_page_and_content_hash"

    create_table :monitor_changes do |t|
      t.references :account, null: false, foreign_key: true
      t.references :monitor_page, null: false, foreign_key: true
      t.references :monitor_page_version, foreign_key: true
      t.bigint :previous_version_id
      t.references :crawl_task, foreign_key: true
      t.string :refer_url
      t.string :change_type
      t.text :summary
      t.integer :importance, null: false, default: 0
      t.integer :relevance, null: false, default: 0
      t.jsonb :change_items, default: []
      t.jsonb :entities, default: []
      t.integer :diff_added, null: false, default: 0
      t.integer :diff_removed, null: false, default: 0
      t.string :analysis_status, null: false, default: "pending"
      t.datetime :notified_at

      t.timestamps
    end
    add_index :monitor_changes, [:account_id, :created_at]
    add_index :monitor_changes, :importance
    add_index :monitor_changes, :refer_url
  end
end
