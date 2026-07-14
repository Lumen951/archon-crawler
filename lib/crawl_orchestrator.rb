require "async"
require "async/semaphore"

# Coordinates crawling across all account types (WeChat, Rednote, and any
# future platforms) in a single interleaved loop, so accounts of different
# platforms are crawled concurrently rather than fully crawling one platform
# before moving on to the next.
#
# Dispatches each account to its platform's crawler via
# `account.class.crawler_class` — see BaseCrawler for how to plug in new
# platforms without touching this file.
class CrawlOrchestrator
  def self.crawl(crawl_task)
    accounts = crawl_task.incomplete_accounts.to_a
    account_concurrency = crawl_task.effective_account_concurrency
    article_concurrency = crawl_task.effective_article_concurrency
    max_pages = Option.max_crawl_pages

    crawl_task.update!(status: :running, started_at: Time.current)
    crawl_task.clear_old_logs

    platform_summary = accounts.group_by(&:platform_name).map { |name, list| "#{name} #{list.size}" }.join("，")
    crawl_task.log(:info, "开始抓取任务，共 #{accounts.size} 个帐号（#{platform_summary}）")
    crawl_task.log(:info, "帐号并发：#{account_concurrency}，文章并发：#{article_concurrency}")
    crawl_task.log(:info, "最大页数：#{max_pages == -1 ? '无限制' : max_pages}")

    start_time = Time.current

    Async do |_task|
      semaphore = Async::Semaphore.new(account_concurrency)

      accounts.each do |account|
        break if crawl_task.reload.paused? || crawl_task.reload.failed?
        break if crawl_task.error_threshold_exceeded?

        semaphore.async do
          crawl_one_account(account, crawl_task, article_concurrency, max_pages)
        end
      end
    end

    elapsed = (Time.current - start_time).round(1)
    crawl_task.reload
    crawl_task.log(:info, "任务全部完成，耗时 #{elapsed} 秒：完成 #{crawl_task.completed_account_count} 个帐号，失败 #{crawl_task.failed_account_count} 个帐号")

    if crawl_task.running?
      if crawl_task.error_threshold_exceeded?
        crawl_task.mark_failed!("累计错误数（#{crawl_task.error_count}）超过阈值，任务终止")
      else
        crawl_task.mark_complete_or_schedule_retry!
      end
    end
  rescue StandardError => e
    crawl_task.mark_failed!(e.message)
    Rails.logger.error("CrawlTask##{crawl_task.id} 失败：#{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
  end

  def self.crawl_one_account(account, crawl_task, article_concurrency, max_pages)
    account.class.crawler_class.crawl_account(
      account, crawl_task,
      article_concurrency: article_concurrency,
      max_pages: max_pages
    )
  rescue CrawlerApiKeyError => e
    # API 密钥错误时，只标记该帐号失败（不暂停整个任务），让其他平台可以继续
    task_account = crawl_task.crawl_task_accounts.find_by(account: account)
    task_account&.mark_failed!(e.message)
    crawl_task.increment_error_count!
    crawl_task.log(:error, "#{account.nickname} (#{account.platform_name}): API 密钥错误，跳过该帐号 — #{e.message}")
  end
end
