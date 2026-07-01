class Article < ApplicationRecord
  belongs_to :account

  validates :url, presence: true, uniqueness: true

  scope :recent, -> { order(published_at: :desc) }
  scope :today, -> { where("published_at >= ?", Time.current.beginning_of_day) }
  scope :last_7_days, -> { where("published_at >= ?", 7.days.ago) }
  scope :last_month, -> { where("published_at >= ?", 1.month.ago) }

  def to_rss_item
    {
      title: title,
      link: url,
      description: digest || content_markdown&.truncate(200),
      pubDate: published_at,
      guid: url
    }
  end
end
