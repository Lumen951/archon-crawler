class CleanupOldTasksJob < ApplicationJob
  queue_as :default

  def perform
    deleted = CrawlTask.cleanup_old_tasks
    Rails.logger.info "[CleanupOldTasksJob] Deleted #{deleted} crawl tasks older than 1 week"
  end
end
