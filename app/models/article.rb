class Article < ApplicationRecord
  belongs_to :account
  belongs_to :crawl_task, optional: true

  validates :url, presence: true, uniqueness: true

  after_create :refresh_account_counters
  after_destroy :refresh_account_counters

  scope :recent, -> { order(published_at: :desc) }
  scope :today, -> { where("published_at >= ?", Time.current.beginning_of_day) }
  scope :yesterday, -> { where(published_at: Time.current.beginning_of_day - 1.day...Time.current.beginning_of_day) }
  scope :last_7_days, -> { where("published_at >= ?", 7.days.ago) }
  scope :last_month, -> { where("published_at >= ?", 1.month.ago) }
  scope :wechat_missing_content, -> { joins(:account).where(accounts: { type: "WechatAccount" }, content_html: nil) }

  # 从原文 URL 重新下载文章内容 (仅支持微信公众号)
  def download_content!
    return false unless url&.include?("mp.weixin.qq.com/s")

    html = WechatCrawler.download_content(url)
    return false if html.blank?

    self.content_html = html
    self.content_markdown = Html2Text.convert(html)
    save!

    Rails.cache.delete("article_content_#{id}")
    true
  end

  def to_rss_item
    {
      title: title,
      link: url,
      description: digest || content_markdown&.truncate(200),
      pubDate: published_at,
      guid: url
    }
  end

  # === Content Analysis Methods (read-only, no DB save) ===

  def platform
    account.type&.gsub("Account", "")&.downcase
  end

  # Cleaned content markdown - removes CSS pollution from WeChat
  def clean_content_markdown
    return nil if content_markdown.blank?

    case platform
    when "wechat"
      # Remove the CSS block at the beginning and cover image
      cleaned = content_markdown
        .gsub(/\A\s*#js[^\n]*\{[^}]*\}\s*/m, '')  # Remove #js_row... block
        .gsub(/\A\s*\.[a-z_][^\n]*\{[^}]*\}\s*/m, '')  # Remove .class blocks
        .gsub(/\A\s*img\s*\{[^}]*\}\s*/m, '')  # Remove img{} block
        .gsub(/\A\s*<style[^>]*>.*?<\/style>\s*/im, '')
        .gsub(/\A\s*<script[^>]*>.*?<\/script>\s*/im, '')
        .gsub(/\A\s*!\[cover_image\]\([^\)]+\)\s*/i, '')  # Remove cover image
        .strip
      cleaned.presence
    when "rednote"
      # For RedNote, desc is better than hashtags-only markdown
      raw_data&.dig("note_card", "desc").presence || content_markdown
    when "twitter"
      content_markdown
    else
      content_markdown
    end
  end

  # Cleaned content HTML
  def clean_content_html
    return nil if content_html.blank?

    case platform
    when "wechat"
      # Remove style and script blocks
      cleaned = content_html
        .gsub(/<style[^>]*>.*?<\/style>/im, '')
        .gsub(/<script[^>]*>.*?<\/script>/im, '')
        .strip
      cleaned.presence
    when "rednote"
      content_html
    when "twitter"
      content_html
    else
      content_html
    end
  end

  # Best available summary text
  def best_digest
    digest.presence || clean_content_markdown&.truncate(200) || title
  end

  # Platform-specific metadata
  def platform_metadata
    case platform
    when "wechat"
      wechat_metadata
    when "rednote"
      rednote_metadata
    when "twitter"
      twitter_metadata
    else
      {}
    end
  end

  # Engagement stats (likes, comments, shares, views)
  def engagement_stats
    case platform
    when "rednote"
      info = raw_data&.dig("note_card", "interact_info") || {}
      {
        likes: info["liked_count"]&.to_i || 0,
        comments: info["comment_count"]&.to_i || 0,
        shares: info["share_count"]&.to_i || 0,
        collected: info["collected_count"]&.to_i || 0
      }
    when "twitter"
      {
        likes: raw_data&.dig("favorite_count")&.to_i || 0,
        retweets: raw_data&.dig("retweet_count")&.to_i || 0,
        replies: raw_data&.dig("reply_count")&.to_i || 0,
        views: raw_data&.dig("view_count")&.to_i || 0
      }
    else
      {}
    end
  end

  # Media URLs (images/videos)
  def media_urls
    case platform
    when "rednote"
      (raw_data&.dig("note_card", "image_list") || []).filter_map { |img| img["url"] }
    when "twitter"
      raw_data&.dig("media_urls") || []
    when "wechat"
      cover_url.present? ? [cover_url] : []
    else
      []
    end
  end

  # Content type classification
  def content_type
    case platform
    when "twitter"
      text = raw_data&.dig("full_text").to_s
      return :retweet if text.start_with?("RT @")
      return :media_focused if media_urls.any? && text.length < 50
      return :quote_tweet if text.include?("https://t.co/") && raw_data&.dig("quote_count")&.to_i > 0
      :original
    when "rednote"
      note_type = raw_data&.dig("note_card", "type")
      note_type == "video" ? :video : :image_post
    when "wechat"
      :article
    else
      :unknown
    end
  end

  # Tags
  def tags
    case platform
    when "rednote"
      (raw_data&.dig("note_card", "tag_list") || []).filter_map { |t| t["name"] }
    when "twitter"
      raw_data&.dig("hashtags") || []
    else
      []
    end
  end

  # Content quality score (0-100)
  def content_quality_score
    score = 0
    md = clean_content_markdown.to_s

    # Has meaningful text
    score += 30 if md.length > 50
    score += 20 if md.length > 200

    # Has media
    score += 20 if media_urls.any?

    # Has engagement
    stats = engagement_stats
    score += 15 if stats.values.any? { |v| v > 0 }

    # Has tags
    score += 10 if tags.any?

    # Has cover image
    score += 5 if cover_url.present?

    [score, 100].min
  end

  private

  def refresh_account_counters
    account.refresh_activity_counters!
  end

  def wechat_metadata
    {
      author_name: raw_data&.dig("author_name"),
      appmsgid: raw_data&.dig("appmsgid"),
      digest_from_api: raw_data&.dig("digest"),
      copyright_type: raw_data&.dig("copyright_type"),
      is_pay_subscribe: raw_data&.dig("is_pay_subscribe")
    }
  end

  def rednote_metadata
    note_card = raw_data&.dig("note_card") || {}
    user = note_card["user"] || {}
    {
      note_type: note_card["type"],
      nickname: user["nickname"],
      avatar: user["avatar"],
      ip_location: note_card["ip_location"],
      last_update_time: note_card["last_update_time"]
    }
  end

  def twitter_metadata
    {
      screen_name: raw_data&.dig("screen_name"),
      user_name: raw_data&.dig("user_name"),
      lang: raw_data&.dig("lang"),
      source: raw_data&.dig("source")
    }
  end
end
