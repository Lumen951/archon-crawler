# Base class for all platform-specific crawlers (WechatCrawler, RednoteCrawler,
# future TwitterCrawler, ...).
#
# CrawlOrchestrator drives one interleaved crawl loop across every account,
# regardless of platform, so different platforms are crawled concurrently
# instead of one platform running to completion before the next one starts.
# Each subclass only needs to implement `.crawl_account`, which crawls a
# single account of that platform and is responsible for:
#   - marking the CrawlTaskAccount running/completed/failed
#   - respecting crawl_task pause/failed/error-threshold state (checked in its
#     own pagination loop)
#   - logging progress via crawl_task.log
#
# It may additionally implement the optional `.platform_crawl_summary` hook
# (see below) to report platform-wide metrics once all accounts are done.
#
# To add a new platform (e.g. Twitter):
#   1. Add an `Account` subclass (STI), implementing `self.crawler_class` to
#      return your new crawler class (see WechatAccount / RednoteAccount).
#   2. Create a crawler class `< BaseCrawler` implementing `.crawl_account`.
#   3. If the platform's API bills per call, also implement
#      `.platform_crawl_summary` to surface the spend in the task log.
#   4. That's it — CrawlOrchestrator picks it up automatically, no changes
#      needed to CrawlJob or CrawlOrchestrator itself.
class BaseCrawler
  # @param account [Account] the account to crawl
  # @param crawl_task [CrawlTask] the current crawl task (for logging/state)
  # @param article_concurrency [Integer] max concurrent article/note downloads
  # @param max_pages [Integer] max pages to paginate through (-1 = unlimited)
  def self.crawl_account(account, crawl_task, article_concurrency:, max_pages:)
    raise NotImplementedError, "#{self} must implement .crawl_account"
  end

  # 可选钩子：本次运行该平台第三方 API 用量的一行摘要（如消耗与余额），没有可报的返回 nil。
  # CrawlOrchestrator 会在该平台所有帐号抓完后调用一次，并把结果拼到"平台抓取完成"日志行上。
  # 不按次计费的平台无需实现。
  # @return [String, nil]
  def self.platform_crawl_summary(_crawl_task)
    nil
  end
end
