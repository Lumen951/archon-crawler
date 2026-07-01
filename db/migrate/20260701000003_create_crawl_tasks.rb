class CreateCrawlTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :crawl_tasks do |t|
      t.json :account_ids
      t.integer :status, default: 0
      t.integer :progress, default: 0
      t.integer :total
      t.integer :error_count, default: 0
      t.text :error_message
      t.integer :account_concurrency
      t.integer :article_concurrency
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end
    add_index :crawl_tasks, :status
  end
end
