class AddScheduledJobIdToCrawlTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :crawl_tasks, :scheduled_job_id, :string
    add_index :crawl_tasks, :scheduled_job_id
  end
end
