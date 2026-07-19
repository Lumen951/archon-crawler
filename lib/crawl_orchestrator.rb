require "async"
require "async/semaphore"
require "set"

# Coordinates crawling across all account types (WeChat, Rednote, and any
# future platforms). Each platform runs in its own concurrent task with an
# independent semaphore, so WeChat throttling doesn't block other platforms.
#
# Dispatches each account to its platform's crawler via
# `account.class.crawler_class` — see BaseCrawler for how to plug in new
# platforms without touching this file.
class CrawlOrchestrator
  def self.crawl(crawl_task)
    # 初始化帐号追踪（已完成的 account 不会被重置）
    crawl_task.setup_account_tracking!

    incomplete_scope = crawl_task.incomplete_accounts
    account_concurrency = crawl_task.effective_account_concurrency
    article_concurrency = crawl_task.effective_article_concurrency
    max_pages = Option.max_crawl_pages

    crawl_task.crawl_task_accounts.failed.or(crawl_task.crawl_task_accounts.running).update_all(status: :pending, error_message: nil, completed_at: nil)
    crawl_task.update!(status: :running, error_message: nil, error_count: 0, platform_error_counts: {}, completed_at: nil, started_at: Time.current)

    platform_summary = Account.subclasses.filter_map { |klass|
      count = klass.where(id: incomplete_scope).count
      "#{klass.new.platform_name} #{count}" if count > 0
    }.join("，")
    crawl_task.log(:info, "开始抓取任务，共 #{incomplete_scope.count} 个帐号（#{platform_summary}）")
    crawl_task.log(:info, "每平台并发：#{account_concurrency}，文章并发：#{article_concurrency}")
    crawl_task.log(:info, "最大页数：#{max_pages == -1 ? '无限制' : max_pages}")

    start_time = Time.current
    skipped_platforms = Set.new

    Async do |_task|
      # Each platform runs in its own concurrent task with its own semaphore.
      # This way WeChat throttling doesn't block Rednote/Twitter.
      barrier = Async::Barrier.new

      Account.subclasses.each do |platform_class|
        platform_accounts = platform_class.where(id: incomplete_scope)
        next if platform_accounts.empty?

        platform_key = platform_class.name

        barrier.async do
          semaphore = Async::Semaphore.new(account_concurrency)

          platform_accounts.find_each do |account|
            break if crawl_task.reload.paused? || crawl_task.reload.failed?

            if crawl_task.error_threshold_exceeded?(platform_key)
              if skipped_platforms.add?(platform_key)
                crawl_task.log(:warn, "#{account.platform_name} 累计错误数超过阈值，跳过该平台剩余帐号，其他平台继续抓取")
              end
              break
            end

            semaphore.async do
              crawl_one_account(account, crawl_task, article_concurrency, max_pages)
              if account.wechat?
                # https://docs.mptext.top/others/%E5%BE%AE%E4%BF%A1%E6%8E%A5%E5%8F%A3%E9%A2%91%E7%8E%87%E9%99%90%E5%88%B6.html#%E5%BE%AE%E4%BF%A1%E8%8E%B7%E5%8F%96%E6%96%87%E7%AB%A0%E5%88%97%E8%A1%A8%E6%8E%A5%E5%8F%A3%E7%9A%84%E9%A2%91%E7%8E%87%E9%99%90%E5%88%B6%E7%A0%94%E7%A9%B6
                # 20分钟请求了 1100 条数据量就触发微信限流
                sleep 20 * account_concurrency
              end
            end
          end
          crawl_task.log(:info, "#{platform_class.new.platform_name} 平台抓取完成") unless crawl_task.reload.paused? || crawl_task.reload.failed?
        end
      end

      barrier.wait
    end

    elapsed = (Time.current - start_time).round(1)
    crawl_task.reload
    crawl_task.log(:info, "任务全部完成，耗时 #{elapsed} 秒：完成 #{crawl_task.completed_account_count} 个帐号，失败 #{crawl_task.failed_account_count} 个帐号")

    if crawl_task.running?
      crawl_task.log(:warn, "以下平台累计错误数超过阈值，已提前终止：#{skipped_platforms.to_a.join('，')}") if skipped_platforms.any?
      crawl_task.mark_complete_or_schedule_retry!
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
  end
end
