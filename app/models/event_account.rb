# 活动研究账号：不抓文章，只承载一次活动调研的配置 —— 事件名（nickname）、
# 搜索关键词、研究目的、官方/指定页面、其它背景信息，全部存在 metadata 的
# event_config 子对象里。
#
# 调研与抓取管线（CrawlTask / CrawlOrchestrator / crawler_class）完全独立：
# 在研究控制台（EventAccountsController#show）启动，创建 EventResearchRun
# 并交给 EventResearchJob 异步执行。
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
class EventAccount < Account
  EVENT_CONFIG_KEY = "event_config"

  # 外键是 accounts.account_id（belongs_to :account），不是按关联名推断的 event_account_id
  has_many :event_research_runs, foreign_key: :account_id, dependent: :destroy

  # 调研不走抓取管线：调度器（due_for_crawl_ids_by_platform）与批量抓取都跳过本平台。
  def self.crawl_enabled?
    false
  end

  def platform_name
    "活动研究"
  end

  def platform_badge_class
    "bg-amber-100 text-amber-700"
  end

  def event_config
    value = metadata.is_a?(Hash) ? metadata[EVENT_CONFIG_KEY] : nil
    value.is_a?(Hash) ? value : {}
  end

  # 只合并 event_config 子对象，不碰 metadata 里的其它键。
  # 统一成字符串键，避免 metadata 里混入 symbol 键（jsonb 序列化时会出现重复键）。
  def event_config=(values)
    base = metadata.is_a?(Hash) ? metadata : {}
    current = event_config
    self.metadata = base.merge(EVENT_CONFIG_KEY => current.merge(values.to_h.stringify_keys))
  end

  def event_url
    event_config["url"].to_s.strip
  end

  def keywords
    Array(event_config["keywords"]).map { |keyword| keyword.to_s.strip }.reject(&:empty?)
  end

  def other_information
    event_config["other_information"].to_s
  end

  def purpose
    event_config["purpose"].to_s
  end

  def weekly_research_enabled?
    ActiveModel::Type::Boolean.new.cast(event_config["weekly_research_enabled"])
  end

  def feishu_chat_id
    event_config["feishu_chat_id"].to_s.strip.presence
  end

  def feishu_receive_id
    event_config["feishu_receive_id"].to_s.strip.presence || feishu_chat_id
  end

  def feishu_receive_id_type
    value = event_config["feishu_receive_id_type"].to_s.strip
    return value if %w[open_id chat_id].include?(value)
    return "chat_id" if feishu_chat_id.present?

    nil
  end

  # 推送目标：活动级配置 > 管理设置里的「活动调研默认推送目标」。
  # 不回退到扫码登录提醒的 feishu_receive_id —— 两类通知的受众不同。
  def feishu_target
    if feishu_receive_id.present?
      { receive_id: feishu_receive_id, receive_id_type: feishu_receive_id_type || "chat_id" }
    elsif Option.event_feishu_receive_id.present?
      { receive_id: Option.event_feishu_receive_id, receive_id_type: Option.event_feishu_receive_id_type.presence || "chat_id" }
    end
  end

  scope :weekly_research_enabled, -> {
    where("metadata -> 'event_config' ->> 'weekly_research_enabled' = ?", "true")
  }

  # IS DISTINCT FROM 而不是 where.not：weekly_research_enabled 为 NULL
  #（从未配置过）的活动也算「未开启」，where.not 的 NOT (NULL) 会把它们漏掉
  scope :weekly_research_disabled, -> {
    where("metadata -> 'event_config' ->> 'weekly_research_enabled' IS DISTINCT FROM ?", "true")
  }

  # 周调研列表筛选（q[with_weekly_research] = enabled / disabled），空值表示不过滤
  scope :with_weekly_research, ->(flag) {
    case flag
    when "enabled" then weekly_research_enabled
    when "disabled" then weekly_research_disabled
    else all
    end
  }

  # 周调研是否真的会执行：既要在配置里开启，账号也不能处于停用状态
  # （WeeklyEventResearchJob 只调研启用中的账号）
  def weekly_research_active?
    weekly_research_enabled? && active?
  end

  def self.ransackable_scopes(auth_object = nil)
    super + %w[with_weekly_research]
  end

  def self.ransackable_scopes_skip_sanitize_args
    super + %w[with_weekly_research]
  end

  # 传给 EventResearch::Researcher 的调研配置（键与 Researcher 的关键字参数对齐）。
  def research_config
    {
      keywords: keywords,
      purpose: purpose.presence,
      other_information: other_information.presence,
      seed_url: event_url.presence
    }
  end

  before_validation :normalize_event_config

  validate :event_url_must_be_http, if: -> { event_url.present? }

  private

  # 指定页面会渲染成 link_to 的 href（控制台与结果展示），必须是 http(s) 链接
  def event_url_must_be_http
    uri = URI.parse(event_url)
    errors.add(:base, "指定页面必须是 http(s) 链接") unless uri.is_a?(URI::HTTP)
  rescue URI::InvalidURIError
    errors.add(:base, "指定页面不是有效的链接")
  end

  def normalize_event_config
    config = event_config.dup
    config["url"] = config["url"].to_s.strip.presence
    config["keywords"] = normalize_keywords(config["keywords"])
    config["other_information"] = config["other_information"].to_s.strip.presence
    config["purpose"] = config["purpose"].to_s.strip.presence
    config["weekly_research_enabled"] = ActiveModel::Type::Boolean.new.cast(config["weekly_research_enabled"])
    config["feishu_chat_id"] = config["feishu_chat_id"].to_s.strip.presence
    config["feishu_receive_id"] = config["feishu_receive_id"].to_s.strip.presence
    config["feishu_receive_id_type"] = config["feishu_receive_id_type"].to_s.strip.presence
    config["feishu_receive_id_type"] = nil unless %w[open_id chat_id].include?(config["feishu_receive_id_type"])
    self.metadata = (metadata.is_a?(Hash) ? metadata : {}).merge(EVENT_CONFIG_KEY => config)
  end

  # 关键词支持数组或换行/中英文逗号分隔的字符串，统一成去重后的字符串数组
  def normalize_keywords(value)
    Array(value)
      .flat_map { |keyword| keyword.to_s.split(/[\n,，]/) }
      .map(&:strip)
      .reject(&:empty?)
      .uniq
  end
end
