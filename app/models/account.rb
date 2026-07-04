class Account < ApplicationRecord
  self.inheritance_column = :type

  has_many :articles, dependent: :destroy

  enum :status, { active: 0, inactive: 1 }

  validates :fakeid, presence: true, uniqueness: true
  validates :nickname, presence: true

  scope :active, -> { where(status: :active) }
  scope :recently_crawled, -> { where.not(last_crawled_at: nil).order(last_crawled_at: :desc) }
  scope :needs_crawling, -> { active.where(last_crawled_at: nil).or(active.where("last_crawled_at < ?", 1.day.ago)) }

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

  def self.ransackable_attributes(auth_object = nil)
    %w[nickname fakeid status type]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[articles]
  end
end
