class AddPlatformErrorCountsToCrawlTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :crawl_tasks, :platform_error_counts, :json, default: {}
  end
end
