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

    # platform_classes (DB-driven) rather than Account.subclasses: in
    # development lazy loading a subclass that has never been referenced
    # would be missing from `subclasses` and silently skipped.
    platform_classes = Account.platform_classes
    platform_summary = platform_classes.filter_map { |klass|
      next if !klass.crawl_enabled?
      count = klass.where(id: incomplete_scope).count
      "#{klass.new.platform_name} #{count}" if count > 0
    }.join("，")
    disabled_platforms = platform_classes.reject(&:crawl_enabled?).map { |k| k.new.platform_name }
    crawl_task.log(:info, "已禁用的平台：#{disabled_platforms.join('，')}") if disabled_platforms.any?
    crawl_task.log(:info, "开始抓取任务，共 #{incomplete_scope.count} 个帐号（#{platform_summary}）")
    crawl_task.log(:info, "每平台并发：#{account_concurrency}，文章并发：#{article_concurrency}")
    crawl_task.log(:info, "最大页数：#{max_pages == -1 ? '无限制' : max_pages}")

    start_time = Time.current
    skipped_platforms = Set.new

    Async do |_task|
      # Each platform runs in its own concurrent task with its own semaphore.
      # This way WeChat throttling doesn't block Rednote/Twitter.
      barrier = Async::Barrier.new

      platform_classes.each do |platform_class|
        unless platform_class.crawl_enabled?
          crawl_task.log(:info, "#{platform_class.new.platform_name} 平台抓取已禁用，跳过")
          next
        end

        platform_accounts = platform_class.where(id: incomplete_scope)
        next if platform_accounts.empty?

        platform_key = platform_class.name

        barrier.async do
          semaphore = Async::Semaphore.new(account_concurrency)
          account_barrier = Async::Barrier.new

          platform_accounts.order(Arel.sql("last_crawled_at ASC NULLS FIRST")).each do |account|
            break if crawl_task.reload.paused? || crawl_task.reload.failed?

            if crawl_task.error_threshold_exceeded?(platform_key)
              if skipped_platforms.add?(platform_key)
                crawl_task.log(:warn, "#{account.platform_name} 累计错误数超过阈值，跳过该平台剩余帐号，其他平台继续抓取")
              end
              break
            end

            account_barrier.async do
              semaphore.acquire do
                next if crawl_task.reload.paused? || crawl_task.reload.failed?
                next if crawl_task.reload.error_threshold_exceeded?(platform_key)
                crawl_one_account(account, crawl_task, article_concurrency, max_pages)
              end
            end
          end

          # 等待该平台所有帐号任务真正结束（semaphore.async 只调度不等待，会导致日志乱序）
          account_barrier.wait
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
      crawl_task.mark_complete_or_fail!
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
