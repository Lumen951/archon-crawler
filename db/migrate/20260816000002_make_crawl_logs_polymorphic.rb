class MakeCrawlLogsPolymorphic < ActiveRecord::Migration[8.1]
  def up
    add_column :crawl_logs, :loggable_type, :string
    add_column :crawl_logs, :loggable_id, :bigint

    execute <<~SQL
      UPDATE crawl_logs SET loggable_type = 'CrawlTask', loggable_id = crawl_task_id
    SQL

    remove_foreign_key :crawl_logs, :crawl_tasks
    remove_column :crawl_logs, :crawl_task_id

    add_index :crawl_logs, [:loggable_type, :loggable_id]
  end

  def down
    add_column :crawl_logs, :crawl_task_id, :bigint

    execute <<~SQL
      UPDATE crawl_logs SET crawl_task_id = loggable_id WHERE loggable_type = 'CrawlTask'
    SQL

    remove_column :crawl_logs, :loggable_type
    remove_column :crawl_logs, :loggable_id

    add_foreign_key :crawl_logs, :crawl_tasks
    add_index :crawl_logs, :crawl_task_id
  end
end
