class Account < ApplicationRecord
  self.inheritance_column = :type

  has_many :articles, dependent: :destroy
  has_many :crawl_task_accounts, dependent: :destroy
  has_many :group_accounts, dependent: :destroy
  has_many :groups, through: :group_accounts
  has_many :tag_accounts, dependent: :destroy
  has_many :tags, through: :tag_accounts

  enum :status, { active: 0, inactive: 1 }

  # How long to wait before re-crawling, by activity tier (see #activity_level).
  CRAWL_INTERVALS = {
    active: 1.day,
    slow: 3.days,
    dormant: 7.days,
    dead: 21.days,
    never: 30.days,
  }.freeze

  validates :fakeid, presence: true, uniqueness: true
  validates :nickname, presence: true

  scope :active, -> { where(status: :active) }
  scope :recently_crawled, -> { where.not(last_crawled_at: nil).order(last_crawled_at: :desc) }
  scope :needs_crawling, -> { active.where(last_crawled_at: nil).or(active.where("last_crawled_at < ?", 1.day.ago)) }
  scope :due_for_crawl, -> { active.where("next_crawl_at IS NULL OR next_crawl_at <= ?", Time.current) }
  scope :with_tag, ->(tag_id) { joins(:tag_accounts).where(tag_accounts: { tag_id: tag_id }) }
  scope :with_any_tag, ->(tag_ids) { joins(:tag_accounts).where(tag_accounts: { tag_id: tag_ids }).distinct }
  scope :without_tag, -> { where.not(id: TagAccount.select(:account_id)) }

  # Activity-based scopes
  scope :uncrawled, -> { where(last_crawled_at: nil) }
  scope :never_published, -> { where(total_articles: 0).where.not(last_crawled_at: nil) }
  scope :published_in_last, ->(days) { where("last_published_at >= ?", days.days.ago) }
  scope :dormant_since, ->(date) { where("last_published_at < ? OR last_published_at IS NULL", date) }
  scope :needs_attention, -> { active.where.not(last_crawled_at: nil).where("total_articles > 0").where("last_published_at < ? OR last_published_at IS NULL", 90.days.ago) }
  scope :by_activity_level, ->(level) {
    case level.to_s
    when "active"    then where("last_published_at >= ?", 7.days.ago)
    when "slow"      then where("last_published_at >= ?", 30.days.ago)
                          .where("last_published_at < ?", 7.days.ago)
    when "dormant"   then where("total_articles > 0")
                          .where("last_published_at >= ?", 90.days.ago)
                          .where("last_published_at < ?", 30.days.ago)
    when "dead"      then where("total_articles > 0")
                          .where("last_published_at < ? OR last_published_at IS NULL", 90.days.ago)
    when "never"     then where(total_articles: 0).where.not(last_crawled_at: nil)
    when "uncrawled" then where(last_crawled_at: nil)
    else all
    end
  }

  def crawl!(concurrency: nil)
    task = CrawlTask.create!(
      account_ids: [id],
      status: :pending,
      article_concurrency: concurrency
    )
    CrawlJob.perform_later(task.id)
    task
  end

  def mark_inactive!
    update!(status: :inactive)
  end

  def rss_items
    articles.recent.limit(50)
  end

  def article_count_summary
    "#{articles.count} 篇文章"
  end

  # Override in subclasses
  def platform_name
    "未知平台"
  end

  # The crawler class (< BaseCrawler) responsible for crawling accounts of
  # this type. Override in subclasses when adding a new platform (see
  # WechatAccount / RednoteAccount) — CrawlOrchestrator uses this to dispatch
  # each account to the right crawler without needing to know every platform.
  def self.crawler_class
    raise NotImplementedError, "#{self} must implement .crawler_class"
  end

  def platform_badge_class
    "bg-gray-100 text-gray-700"
  end

  def avatar_url
    round_head_img
  end

  def wechat?
    is_a?(WechatAccount)
  end

  def rednote?
    is_a?(RednoteAccount)
  end

  def twitter?
    is_a?(TwitterAccount)
  end

  # === Activity & Health ===

  # Returns the activity tier for this account, derived from `last_published_at`.
  # This is the single source of truth for activity classification; the
  # `by_activity_level` scope mirrors these exact buckets in SQL.
  def activity_level
    return :uncrawled if last_crawled_at.nil?
    return :never if total_articles.to_i == 0
    return :dead if last_published_at.nil?
    return :active if last_published_at >= 7.days.ago
    return :slow if last_published_at >= 30.days.ago
    return :dormant if last_published_at >= 90.days.ago
    :dead
  end

  # Recompute and save all activity counters for this account.
  def refresh_activity_counters!
    now = Time.current
    articles_scope = articles.select(:published_at)

    attrs = {
      articles_count: articles_scope.count,
      total_articles: articles_scope.count,
      articles_last_7_days: articles_scope.where("published_at >= ?", 7.days.ago).count,
      articles_last_30_days: articles_scope.where("published_at >= ?", 30.days.ago).count,
      last_published_at: articles_scope.order(Arel.sql("published_at DESC NULLS LAST")).first&.published_at,
    }
    attrs[:activity_score] = self.class.compute_activity_score(attrs)
    update_columns(attrs)
  end

  # Update crawl schedule after a successful crawl: record when we crawled and
  # compute the next due time from this account's publish activity tier.
  def mark_crawled!(at: Time.current)
    interval = self.class.crawl_interval_for(last_published_at: last_published_at, total_articles: total_articles)
    update_columns(last_crawled_at: at, next_crawl_at: at + interval)
  end

  # Next crawl time based on the last crawl and current activity tier.
  # nil for never-crawled accounts (treated as due immediately).
  def compute_next_crawl_at
    return nil if last_crawled_at.nil?
    last_crawled_at + self.class.crawl_interval_for(last_published_at: last_published_at, total_articles: total_articles)
  end

  # === Class Methods ===

  def self.compute_activity_score(attrs)
    score = 0
    score += 30 if attrs[:articles_last_7_days].to_i > 0
    score += 25 if attrs[:articles_last_30_days].to_i > 3
    score += 25 if attrs[:articles_last_30_days].to_i > 10
    score += 20 if attrs[:articles_count].to_i > 50
    [score, 100].min
  end

  # Crawl interval for an already-crawled account, mirroring #activity_level
  # buckets. Computed from the given attrs so it works before columns are saved.
  def self.crawl_interval_for(last_published_at:, total_articles:)
    return CRAWL_INTERVALS[:never] if total_articles.to_i == 0
    return CRAWL_INTERVALS[:dead] if last_published_at.nil?

    if last_published_at >= 7.days.ago
      CRAWL_INTERVALS[:active]
    elsif last_published_at >= 30.days.ago
      CRAWL_INTERVALS[:slow]
    elsif last_published_at >= 90.days.ago
      CRAWL_INTERVALS[:dormant]
    else
      CRAWL_INTERVALS[:dead]
    end
  end

  # IDs of active accounts due for crawling, prioritized and capped by limit.
  # Order: never-crawled first, then most active, then longest overdue.
  def self.due_for_crawl_ids(limit:)
    due_for_crawl
      .order(Arel.sql("next_crawl_at IS NULL DESC, activity_score DESC, next_crawl_at ASC"))
      .limit(limit)
      .pluck(:id)
  end

  def self.activity_summary
    puts "=" * 80
    puts "Account Activity Summary — #{Time.current.strftime('%Y-%m-%d %H:%M')}"
    puts "=" * 80
    puts "Platform".ljust(16) + "Total".rjust(8) + "Active(≤7d)".rjust(14) + "Slow(8-30d)".rjust(14) + "Dormant(31-90d)".rjust(18) + "Dead(>90d)".rjust(14) + "Never".rjust(8) + "Uncrawled".rjust(10)
    puts "-" * 100

    descendants = Account.platform_classes
    descendants.each do |klass|
      scope = klass.all
      puts "#{klass.new.platform_name.ljust(14)} " \
           "#{scope.count.to_s.rjust(8)} " \
           "#{scope.where("last_published_at >= ?", 7.days.ago).count.to_s.rjust(14)} " \
           "#{scope.where("last_published_at >= ?", 30.days.ago).where("last_published_at < ?", 7.days.ago).count.to_s.rjust(14)} " \
           "#{scope.where("total_articles > 0").where("last_published_at >= ?", 90.days.ago).where("last_published_at < ?", 30.days.ago).count.to_s.rjust(18)} " \
           "#{scope.where("total_articles > 0").where("last_published_at < ? OR last_published_at IS NULL", 90.days.ago).count.to_s.rjust(14)} " \
           "#{scope.where(total_articles: 0).where.not(last_crawled_at: nil).count.to_s.rjust(8)} " \
           "#{scope.where(last_crawled_at: nil).count.to_s.rjust(10)}"
    end
    puts "-" * 100

    total = Account.all
    puts "#{'All'.ljust(14)} " \
         "#{total.count.to_s.rjust(8)} " \
         "#{total.where("last_published_at >= ?", 7.days.ago).count.to_s.rjust(14)} " \
         "#{total.where("last_published_at >= ?", 30.days.ago).where("last_published_at < ?", 7.days.ago).count.to_s.rjust(14)} " \
         "#{total.where("total_articles > 0").where("last_published_at >= ?", 90.days.ago).where("last_published_at < ?", 30.days.ago).count.to_s.rjust(18)} " \
         "#{total.where("total_articles > 0").where("last_published_at < ? OR last_published_at IS NULL", 90.days.ago).count.to_s.rjust(14)} " \
         "#{total.where(total_articles: 0).where.not(last_crawled_at: nil).count.to_s.rjust(8)} " \
         "#{total.where(last_crawled_at: nil).count.to_s.rjust(10)}"
    puts "=" * 80
    nil
  end

  # Account STI subclasses currently represented in the DB, sorted by name.
  # Drives platform filtering/breakdown deterministically. Unlike
  # `Account.descendants`, this does not depend on autoload state — in
  # development `descendants` is empty until each subclass has been loaded.
  def self.platform_classes
    Account.distinct.pluck(:type).sort.map(&:constantize)
  end

  def self.platform_activity_stats
    platform_classes.map do |klass|
      scope = klass.all
      {
        platform: klass.new.platform_name,
        total: scope.count,
        active:    scope.by_activity_level("active").count,
        slow:      scope.by_activity_level("slow").count,
        dormant:   scope.by_activity_level("dormant").count,
        dead:      scope.by_activity_level("dead").count,
        never:     scope.by_activity_level("never").count,
        uncrawled: scope.by_activity_level("uncrawled").count,
        avg_score: scope.average(:activity_score)&.round(1) || 0,
      }
    end
  end

  def self.ransackable_attributes(auth_object = nil)
    %w[nickname fakeid status type last_published_at activity_score
       articles_last_7_days articles_last_30_days total_articles]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[articles]
  end

  def self.ransackable_scopes(auth_object = nil)
    %w[with_tag_id by_activity_level]
  end

  def self.ransackable_scopes_skip_sanitize_args
    %w[with_tag_id by_activity_level]
  end

  # Whether crawling is enabled for this platform.
  # Checks the "crawl_<platform>_enabled" option (default true).
  def self.crawl_enabled?
    return true if self == Account
    platform_key = name.sub("Account", "").underscore
    Option.get("crawl_#{platform_key}_enabled") != "false"
  end

  scope :with_tag_id, ->(tag_id) {
    if tag_id.blank? || tag_id == "all"
      all
    elsif tag_id == "none"
      without_tag
    else
      with_tag(tag_id)
    end
  }
end
