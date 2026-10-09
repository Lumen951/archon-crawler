# == Schema Information
#
# Table name: articles
#
#  id               :bigint           not null, primary key
#  author           :string
#  content_html     :text
#  content_markdown :text
#  cover_url        :string
#  digest           :text
#  published_at     :datetime
#  raw_data         :json
#  title            :string           not null
#  url              :string           not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  crawl_task_id    :bigint
#
# Indexes
#
#  index_articles_on_account_id_and_published_at   (account_id,published_at DESC)
#  index_articles_on_content_markdown_trgm         (content_markdown) USING gin
#  index_articles_on_crawl_task_id                 (crawl_task_id)
#  index_articles_on_digest_trgm                   (digest) USING gin
#  index_articles_on_published_at                  (published_at)
#  index_articles_on_published_at_desc_nulls_last  (published_at)
#  index_articles_on_title_trgm                    (title) USING gin
#  index_articles_on_url                           (url) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (crawl_task_id => crawl_tasks.id)
#
class Article < ApplicationRecord
  belongs_to :account
  belongs_to :crawl_task, optional: true

  validates :url, presence: true, uniqueness: true

  after_create :refresh_account_counters
  after_destroy :refresh_account_counters

  scope :recent, -> { order(Arel.sql("published_at DESC NULLS LAST")) }
  scope :today, -> { where("published_at >= ?", Time.current.beginning_of_day) }
  scope :yesterday, -> { where(published_at: Time.current.beginning_of_day - 1.day...Time.current.beginning_of_day) }
  scope :last_7_days, -> { where("published_at >= ?", 7.days.ago) }
  scope :last_month, -> { where("published_at >= ?", 1.month.ago) }
  scope :wechat_missing_content, -> { joins(:account).where(accounts: { type: "WechatAccount" }, content_html: nil) }

  # pg_trgm derives trigrams from runs of three characters, so LIKE/ILIKE on a
  # shorter term yields no trigram, cannot use the GIN indexes at all, and
  # degrades to reading every article — detoasting content_markdown, which
  # 177,233 of 177,266 rows have. A short term AND-ed with an index-usable long
  # one is no better (22.4s measured): the long term's bitmap merely feeds every
  # candidate into the short term's per-row filter. `show_trgm` does report
  # trigrams for a two-character *string* because it pads with spaces, but LIKE
  # uses the unpadded form, so three characters is a hard floor for the index.
  #
  # What such a scan costs depends entirely on how quickly it reaches matches,
  # because the LIMIT can only stop a scan that is finding rows:
  #
  #   教育   2 chars, 36,658 matches    331ms
  #   甄劢   2 chars,      0 matches   27.8s
  #   甄劢甲 3 chars,      0 matches     10ms  (index-served)
  #
  # Chinese two-character words are the norm, so refusing them outright is a
  # large hole in the product. Instead the scan is capped (#with_search_timeout):
  # high-frequency terms answer as usual and the rare ones are cut off with an
  # explanation. Proper CJK indexing — a 2-gram index such as pg_bigm — is the
  # real fix, and would make this cap unnecessary.
  MIN_SEARCH_TERM_LENGTH = 3

  # How long a scan behind a term too short for the indexes may run. Comfortably
  # above the 331ms a high-frequency term needs, well below the 27.8s a rare one
  # would take.
  SEARCH_TIMEOUT_MS = 2_500

  # Terms too short to be served by the trigram indexes, and so the terms that
  # force #with_search_timeout to cap the scan.
  def self.short_search_terms(keyword)
    keyword.to_s.split.select { |term| term.length < MIN_SEARCH_TERM_LENGTH }
  end

  # The cap in milliseconds. A method rather than the bare constant so tests can
  # stub it down and exercise the cut-off path without a slow query.
  def self.search_timeout_ms
    SEARCH_TIMEOUT_MS
  end

  # Runs the block under a statement timeout when the keyword cannot use the
  # trigram indexes, and returns nil if the scan was cut off — callers show
  # #short_search_timeout_message instead of an empty list. Keywords whose every
  # term is three characters or longer are index-served and run untouched.
  #
  # The block's relation is loaded here, inside the transaction: a lazy relation
  # would run its query after COMMIT, where SET LOCAL no longer applies.
  # `requires_new` keeps the cap scoped to this block, and lets a cancelled
  # statement roll back to its savepoint rather than poison an enclosing
  # transaction (the test suite runs every test inside one).
  def self.with_search_timeout(keyword)
    return yield if short_search_terms(keyword).empty?

    transaction(requires_new: true) do
      connection.execute("SET LOCAL statement_timeout = #{search_timeout_ms}")
      result = yield
      result.load if result.is_a?(ActiveRecord::Relation)
      result
    end
  rescue ActiveRecord::QueryCanceled
    nil
  end

  # Why a search came back empty-handed, or nil when the keyword was fine. Kept
  # here so the web, REST API and MCP surfaces explain it identically.
  def self.short_search_timeout_message(keyword)
    short = short_search_terms(keyword).first
    return nil if short.nil?

    "关键词「#{short}」只有 #{short.length} 个字符，无法使用索引，" \
      "搜索在 #{format('%.1f', search_timeout_ms / 1000.0)} 秒后超时。" \
      "请换用至少 #{MIN_SEARCH_TERM_LENGTH} 个字符的关键词。"
  end

  # Fuzzy keyword search over title, digest and content_markdown.
  # Space-separated terms are AND-ed; every term must appear as a substring in
  # at least one of the three columns. Backed by the pg_trgm GIN indexes on all
  # three columns; content_html is never searched (content_markdown is the
  # canonical body text). Callers must run the query inside
  # #with_search_timeout — see the note above it for why.
  def self.search_keyword(keyword)
    terms = keyword.to_s.split.reject(&:blank?)
    return all if terms.empty?

    terms.reduce(all) do |scope, term|
      pattern = "%#{sanitize_sql_like(term)}%"
      scope.where("title ILIKE :p OR digest ILIKE :p OR content_markdown ILIKE :p", p: pattern)
    end
  end

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
        .gsub(/\A\s*#js[^\n]*\{[^}]*\}\s*/m, "")  # Remove #js_row... block
        .gsub(/\A\s*\.[a-z_][^\n]*\{[^}]*\}\s*/m, "")  # Remove .class blocks
        .gsub(/\A\s*img\s*\{[^}]*\}\s*/m, "")  # Remove img{} block
        .gsub(/\A\s*<style[^>]*>.*?<\/style>\s*/im, "")
        .gsub(/\A\s*<script[^>]*>.*?<\/script>\s*/im, "")
        .gsub(/\A\s*!\[cover_image\]\([^\)]+\)\s*/i, "")  # Remove cover image
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
        .gsub(/<style[^>]*>.*?<\/style>/im, "")
        .gsub(/<script[^>]*>.*?<\/script>/im, "")
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
      cover_url.present? ? [ cover_url ] : []
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

    [ score, 100 ].min
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
