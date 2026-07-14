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
# To add a new platform (e.g. Twitter):
#   1. Add an `Account` subclass (STI), implementing `self.crawler_class` to
#      return your new crawler class (see WechatAccount / RednoteAccount).
#   2. Create a crawler class `< BaseCrawler` implementing `.crawl_account`.
#   3. That's it — CrawlOrchestrator picks it up automatically, no changes
#      needed to CrawlJob or CrawlOrchestrator itself.
class BaseCrawler
  # @param account [Account] the account to crawl
  # @param crawl_task [CrawlTask] the current crawl task (for logging/state)
  # @param article_concurrency [Integer] max concurrent article/note downloads
  # @param max_pages [Integer] max pages to paginate through (-1 = unlimited)
  def self.crawl_account(account, crawl_task, article_concurrency:, max_pages:)
    raise NotImplementedError, "#{self} must implement .crawl_account"
  end
end
