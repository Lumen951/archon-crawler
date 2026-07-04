class CrawlJob < ApplicationJob
  queue_as :default

  # @param crawl_task_id [Integer] ID of the CrawlTask to execute
  def perform(crawl_task_id = nil)
    if crawl_task_id.nil?
      crawl_task = CrawlTask.create!(account_ids: nil, status: :pending)
    else
      crawl_task = CrawlTask.find(crawl_task_id)
    end

    if crawl_task.completed?
      Rails.logger.info("CrawlJob: Task ##{crawl_task.id} already #{crawl_task.status}, skipping")
      return
    end

    # 初始化帐号追踪（已完成的 account 不会被重置）
    crawl_task.setup_account_tracking!

    accounts = crawl_task.incomplete_accounts
    has_wechat  = accounts.where(type: "WechatAccount").exists?
    has_rednote = accounts.where(type: "RednoteAccount").exists?

    WechatCrawler.crawl(crawl_task)  if has_wechat
    RednoteCrawler.crawl(crawl_task) if has_rednote

    unless has_wechat || has_rednote
      crawl_task.mark_failed!("没有可抓取的帐号")
    end
  end
end
