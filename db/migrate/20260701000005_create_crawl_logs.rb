class CreateCrawlLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :crawl_logs do |t|
      t.references :crawl_task, null: false, foreign_key: true, index: true
      t.string :level, null: false
      t.text :message
      t.text :context
      t.datetime :logged_at

      t.timestamps
    end
    add_index :crawl_logs, :level
    add_index :crawl_logs, :logged_at
  end
end
