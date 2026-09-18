# One tracked official website (deepseek.com, openai.com, ...), reusing the
# whole Account ecosystem: import UI, crawl tasks, activity tiers, bulk
# actions and RSS work exactly like the other platforms. Crawler config (entry
# url / max_pages) and website-level check status live in metadata; monitor
# pages and detected changes hang off the account.
# == Schema Information
#
# Table name: accounts
#
#  id                    :bigint           not null, primary key
#  activity_score        :integer          default(0), not null
#  articles_count        :integer          default(0), not null
#  articles_last_30_days :integer          default(0), not null
#  articles_last_7_days  :integer          default(0), not null
#  crawl_rule            :jsonb            not null
#  fakeid                :string           not null
#  last_crawled_at       :datetime
#  last_published_at     :datetime
#  metadata              :jsonb
#  next_crawl_at         :datetime
#  nickname              :string           not null
#  round_head_img        :string
#  status                :integer          default(0)
#  total_articles        :integer          default(0)
#  twitter_screen_name   :string
#  type                  :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#
# Indexes
#
#  index_accounts_on_fakeid                        (fakeid) UNIQUE
#  index_accounts_on_metadata                      (metadata) USING gin
#  index_accounts_on_status                        (status)
#  index_accounts_on_status_and_last_published_at  (status,last_published_at)
#  index_accounts_on_status_and_next_crawl_at      (status,next_crawl_at)
#  index_accounts_on_twitter_screen_name           (twitter_screen_name)
#  index_accounts_on_type                          (type)
#
class WebsiteAccount < Account
  # STI: Rails infers the FK from the subclass name (website_account_id), so
  # both associations must point back at account_id explicitly.
  has_many :monitor_pages, dependent: :destroy, foreign_key: :account_id
  has_many :monitor_changes, dependent: :destroy, foreign_key: :account_id

  validate :crawl_rule_is_valid

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

  # Website accounts either use the established sitemap monitor or a bounded
  # listing rule. A missing rule deliberately preserves the sitemap behavior.
  def crawl_mode
    crawl_rule.fetch("mode", "sitemap").to_s.presence_in(%w[sitemap listing]) || "sitemap"
  end

  # A listing account is created before its asynchronous rule generator has
  # produced selectors. It is intentionally runnable only after the rule is
  # complete; WebsiteCrawler turns this state into a visible crawl failure.
  def listing_rule_unconfigured?
    WebsiteCrawler::ListingRule.unconfigured_listing?(crawl_rule)
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

  private

  def crawl_rule_is_valid
    return if WebsiteCrawler::ListingRule.unconfigured_listing?(crawl_rule)

    WebsiteCrawler::ListingRule.new(self, crawl_rule)
  rescue WebsiteCrawler::ListingRule::InvalidRule => e
    errors.add(:crawl_rule, e.message)
  end
end
