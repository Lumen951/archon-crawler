# == Schema Information
#
# Table name: accounts
#
#  id                    :bigint           not null, primary key
#  activity_score        :integer          default(0), not null
#  articles_count        :integer          default(0), not null
#  articles_last_30_days :integer          default(0), not null
#  articles_last_7_days  :integer          default(0), not null
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
class RednoteAccount < Account
  def platform_name
    "小红书"
  end

  def platform_badge_class
    "bg-rose-100 text-rose-700"
  end

  def self.crawler_class
    RednoteCrawler
  end
end
