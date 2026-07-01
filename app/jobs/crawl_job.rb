class CrawlJob < ApplicationJob
  queue_as :default

  # @param crawl_task_id [Integer] ID of the CrawlTask to execute
  def perform(crawl_task_id)
    crawl_task = CrawlTask.find(crawl_task_id)

    if crawl_task.completed? || crawl_task.failed?
      Rails.logger.info("CrawlJob: Task ##{crawl_task_id} already #{crawl_task.status}, skipping")
      return
    end

    WechatCrawler.crawl(crawl_task)
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("CrawlJob: CrawlTask not found: #{e.message}")
  end
end
