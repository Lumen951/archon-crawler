# One tracked official website (deepseek.com, openai.com, ...), reusing the
# whole Account ecosystem: import UI, crawl tasks, activity tiers, bulk
# actions and RSS work exactly like the other platforms. Crawler config (entry
# url / max_pages) and website-level check status live in metadata; monitor
# pages and detected changes hang off the account.
class WebsiteAccount < Account
  # STI: Rails infers the FK from the subclass name (website_account_id), so
  # both associations must point back at account_id explicitly.
  has_many :monitor_pages, dependent: :destroy, foreign_key: :account_id
  has_many :monitor_changes, dependent: :destroy, foreign_key: :account_id

  DEFAULT_MAX_PAGES = 50
  # Hard ceiling regardless of metadata — unlike other platforms' max_pages
  # (listing pagination depth), this bounds how many distinct URLs
  # WebsiteCrawler tracks/fetches per account, so a misconfigured account (or
  # an over-eager sitemap) can't balloon into crawling hundreds of pages.
  MAX_PAGES_CEILING = 100

  def platform_name
    "官网"
  end

  def platform_badge_class
    "bg-violet-100 text-violet-700"
  end

  def self.crawler_class
    WebsiteCrawler
  end

  def website?
    true
  end

  # Entry URL from import time; falls back to https://<fakeid>.
  def url
    metadata["url"].presence || "https://#{fakeid}"
  end

  def max_pages
    (metadata["max_pages"] || DEFAULT_MAX_PAGES).to_i.clamp(1, MAX_PAGES_CEILING)
  end

  # True while the nickname is still the auto-derived domain — the crawler
  # replaces it with the site title on the first successful homepage fetch.
  def placeholder_nickname?
    nickname == fakeid
  end

  def last_change_at
    value = metadata["last_change_at"]
    Time.zone.parse(value) if value.present?
  end

  def last_check_status
    metadata["last_status"]
  end

  def last_error
    metadata["last_error"]
  end

  # Called by WebsiteCrawler after each check — the Account-based
  # counterpart of the old MonitoredWebsite#mark_checked!. Activity counters
  # are refreshed first so mark_crawled! schedules the next crawl from the
  # site's real change activity (sites that update often get crawled daily).
  def mark_checked!(changed:, error:)
    now = Time.current
    meta = metadata || {}
    meta["last_status"] = error ? "error" : "success"
    meta["last_error"] = error
    meta["last_change_at"] = now.iso8601 if changed
    update_columns(metadata: meta)
    refresh_activity_counters!
    mark_crawled!(at: now)
  end
end
