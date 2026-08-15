class RemoveAutoRetryFromCrawlTasks < ActiveRecord::Migration[8.1]
  def change
    remove_column :crawl_tasks, :retry_count, :integer, default: 0, null: false
    remove_column :crawl_tasks, :scheduled_job_id, :string
  end
end
