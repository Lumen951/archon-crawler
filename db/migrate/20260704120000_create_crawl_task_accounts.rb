class CreateCrawlTaskAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :crawl_task_accounts do |t|
      t.references :crawl_task, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.integer :status, default: 0, null: false
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :crawl_task_accounts, [:crawl_task_id, :account_id], unique: true, name: "idx_crawl_task_accounts_unique"
    add_index :crawl_task_accounts, [:crawl_task_id, :status], name: "idx_crawl_task_accounts_status"
  end
end
