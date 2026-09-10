class CrawlJob < ApplicationJob
  queue_as :default

  # @param crawl_task_id [Integer] ID of the CrawlTask to execute
  def perform(crawl_task_id = nil)
    if crawl_task_id.nil?
      # Scheduled run: only crawl accounts due per their activity tier, capped
      # by the daily budget. Manual "crawl all" runs still pass a task id.
      account_ids = Account.due_for_crawl_ids_by_platform
      if account_ids.empty?
        Rails.logger.info("CrawlJob: no accounts due for crawl, skipping")
        return
      end
      crawl_task = CrawlTask.create!(account_ids: account_ids, status: :pending)
    else
      crawl_task = CrawlTask.find(crawl_task_id)
    end

    if crawl_task.completed?
      Rails.logger.info("CrawlJob: Task ##{crawl_task.id} already #{crawl_task.status}, skipping")
      return
    end

    CrawlOrchestrator.crawl(crawl_task)
    WechatContentDownloadJob.perform_later
  end
end
