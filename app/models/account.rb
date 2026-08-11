class Account < ApplicationRecord
  self.inheritance_column = :type

  has_many :articles, dependent: :destroy
  has_many :crawl_task_accounts, dependent: :destroy
  has_many :group_accounts, dependent: :destroy
  has_many :groups, through: :group_accounts
  has_many :tag_accounts, dependent: :destroy
  has_many :tags, through: :tag_accounts

  enum :status, { active: 0, inactive: 1 }

  validates :fakeid, presence: true, uniqueness: true
  validates :nickname, presence: true

  scope :active, -> { where(status: :active) }
  scope :recently_crawled, -> { where.not(last_crawled_at: nil).order(last_crawled_at: :desc) }
  scope :needs_crawling, -> { active.where(last_crawled_at: nil).or(active.where("last_crawled_at < ?", 1.day.ago)) }
  scope :with_tag, ->(tag_id) { joins(:tag_accounts).where(tag_accounts: { tag_id: tag_id }) }
  scope :with_any_tag, ->(tag_ids) { joins(:tag_accounts).where(tag_accounts: { tag_id: tag_ids }).distinct }
  scope :without_tag, -> { where.not(id: TagAccount.select(:account_id)) }

  # Activity-based scopes
  scope :never_published, -> { where(total_articles: 0) }
  scope :published_in_last, ->(days) { where("last_published_at >= ?", days.days.ago) }
  scope :dormant_since, ->(date) { where("last_published_at < ? OR last_published_at IS NULL", date) }
  scope :needs_attention, -> { active.where("last_published_at < ? OR last_published_at IS NULL", 90.days.ago).where("total_articles > 0") }
  scope :by_activity_level, ->(level) {
    case level.to_s
    when "very_active" then where("articles_last_7_days > 0")
    when "active"      then where("articles_last_30_days > 0 AND articles_last_7_days = 0")
    when "slow"        then where("articles_last_30_days = 0").where("last_published_at >= ?", 90.days.ago).where("total_articles > 0")
    when "dormant"     then where("total_articles > 0").where("last_published_at < ? OR last_published_at IS NULL", 90.days.ago)
    when "dead"        then where(total_articles: 0)
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

  # Returns the publish status category for this account.
  def publish_status
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
      last_published_at: articles_scope.order(published_at: :desc).first&.published_at,
    }
    attrs[:activity_score] = self.class.compute_activity_score(attrs)
    update_columns(attrs)
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

  def self.activity_summary
    puts "=" * 80
    puts "Account Activity Summary — #{Time.current.strftime('%Y-%m-%d %H:%M')}"
    puts "=" * 80
    puts "Platform".ljust(16) + "Total".rjust(8) + "Active(≤7d)".rjust(14) + "Slow(8-30d)".rjust(14) + "Dormant(31-90d)".rjust(18) + "Dead(>90d)".rjust(14) + "Never".rjust(8)
    puts "-" * 92

    descendants = Account.descendants.sort_by(&:name)
    descendants.each do |klass|
      scope = klass.all
      puts "#{klass.new.platform_name.ljust(14)} " \
           "#{scope.count.to_s.rjust(8)} " \
           "#{scope.where("last_published_at >= ?", 7.days.ago).count.to_s.rjust(14)} " \
           "#{scope.where("last_published_at >= ?", 30.days.ago).where("last_published_at < ?", 7.days.ago).count.to_s.rjust(14)} " \
           "#{scope.where("total_articles > 0").where("last_published_at >= ?", 90.days.ago).where("last_published_at < ?", 30.days.ago).count.to_s.rjust(18)} " \
           "#{scope.where("total_articles > 0").where("last_published_at < ? OR last_published_at IS NULL", 90.days.ago).count.to_s.rjust(14)} " \
           "#{scope.where(total_articles: 0).count.to_s.rjust(8)}"
    end
    puts "-" * 92

    total = Account.all
    puts "#{'All'.ljust(14)} " \
         "#{total.count.to_s.rjust(8)} " \
         "#{total.where("last_published_at >= ?", 7.days.ago).count.to_s.rjust(14)} " \
         "#{total.where("last_published_at >= ?", 30.days.ago).where("last_published_at < ?", 7.days.ago).count.to_s.rjust(14)} " \
         "#{total.where("total_articles > 0").where("last_published_at >= ?", 90.days.ago).where("last_published_at < ?", 30.days.ago).count.to_s.rjust(18)} " \
         "#{total.where("total_articles > 0").where("last_published_at < ? OR last_published_at IS NULL", 90.days.ago).count.to_s.rjust(14)} " \
         "#{total.where(total_articles: 0).count.to_s.rjust(8)}"
    puts "=" * 80
    nil
  end

  def self.platform_activity_stats
    Account.descendants.sort_by(&:name).map do |klass|
      scope = klass.all
      {
        platform: klass.new.platform_name,
        total: scope.count,
        active_7d: scope.where("last_published_at >= ?", 7.days.ago).count,
        active_30d: scope.where("last_published_at >= ?", 30.days.ago).count,
        dormant_90d: scope.active.where("total_articles > 0").where("last_published_at < ? OR last_published_at IS NULL", 90.days.ago).count,
        never_published: scope.where(total_articles: 0).count,
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
