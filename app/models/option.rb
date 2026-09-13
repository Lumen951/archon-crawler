# == Schema Information
#
# Table name: options
#
#  id         :bigint           not null, primary key
#  opt_key    :string           not null
#  opt_value  :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_options_on_opt_key  (opt_key) UNIQUE
#
class Option < ApplicationRecord
  self.table_name = 'options'

  # 微信公众号平台（mp_native）扫码登录会话的有效期。
  #
  # 这是「有效期」的唯一定义处：api_client 落库、设置页文案、README 均以此为准。
  # 注意它只是本地时间戳启发式——微信可能提前作废会话，真正的权威是
  # WechatMpNativeApiClient.validate_session 的实时探测（每日由
  # FeishuLoginReminderJob 体检）。
  WECHAT_MP_SESSION_TTL = 4.days

  validates :opt_key, presence: true, uniqueness: true

  class << self
    def get(key, default = nil)
      option = find_by(opt_key: key)
      option&.opt_value.presence || default
    end

    def set(key, value, description: nil)
      option = find_or_initialize_by(opt_key: key)
      option.opt_value = value.to_s
      option.save!
    end

    def delete(key)
      find_by(opt_key: key)&.destroy
    end

    def [](key)
      get(key)
    end

    def []=(key, value)
      set(key, value)
    end

    def exists?(key)
      where(opt_key: key).exists?
    end

    def default_article_concurrency
      (get('default_article_concurrency') || 10).to_i
    end

    def default_account_concurrency
      (get('default_account_concurrency') || 3).to_i
    end

    def max_crawl_pages
      (get('max_crawl_pages') || 1).to_i
    end

    # Max accounts crawled per platform per scheduled run (daily budget,
    # anti-throttle cap). Each platform has its own budget, keyed by
    # `daily_crawl_budget_<platform>` (e.g. `daily_crawl_budget_wechat`).
    # Falls back to the legacy global `daily_crawl_budget`, then the default.
    DAILY_CRAWL_BUDGET_DEFAULT = 200

    def daily_crawl_budget_for(platform_key)
      value = get("daily_crawl_budget_#{platform_key}") || get("daily_crawl_budget")
      (value || DAILY_CRAWL_BUDGET_DEFAULT).to_i
    end

    # Verbose logging mode
    def verbose_mode?
      get('crawler_verbose_mode') == 'true'
    end

    # RedNote (Xiaohongshu) API key helpers
    def rednote_api_key
      get('rednote_api_key')
    end

    def rednote_api_key=(val)
      set('rednote_api_key', val)
    end

    def rednote_api_key_valid?
      rednote_api_key.present?
    end

    # TikHub API key helpers (for Rednote user search)
    def tikhub_api_key
      get('tikhub_api_key')
    end

    def tikhub_api_key=(val)
      set('tikhub_api_key', val)
    end

    def tikhub_api_key_valid?
      tikhub_api_key.present?
    end

    # WeChat API provider helpers
    # Returns "mptext" (default) or "dajiala"
    def wechat_api_provider
      get('wechat_api_provider') || 'mp_native'
    end

    def wechat_api_provider=(val)
      set('wechat_api_provider', val)
    end

    # WeChat 正文下载限流参数：请求数 / 窗口秒数（默认 20 次/60 秒，保守避免触发限流）
    def wechat_download_rate_limit
      (get('wechat_download_rate_limit') || 20).to_i
    end

    def wechat_download_rate_limit=(val)
      set('wechat_download_rate_limit', val)
    end

    def wechat_download_rate_window
      (get('wechat_download_rate_window') || 60).to_i
    end

    def wechat_download_rate_window=(val)
      set('wechat_download_rate_window', val)
    end

    # Dajiala API key helpers
    def dajiala_api_key
      get('dajiala_api_key')
    end

    def dajiala_api_key=(val)
      set('dajiala_api_key', val)
    end

    def dajiala_api_key_valid?
      dajiala_api_key.present?
    end

    # MP Native (QR code login) helpers
    def wechat_mp_cookie
      get('wechat_mp_cookie')
    end

    def wechat_mp_cookie=(val)
      set('wechat_mp_cookie', val)
    end

    def wechat_mp_token
      get('wechat_mp_token')
    end

    def wechat_mp_token=(val)
      set('wechat_mp_token', val)
    end

    def wechat_mp_expires_at
      get('wechat_mp_expires_at')
    end

    def wechat_mp_expires_at=(val)
      set('wechat_mp_expires_at', val)
    end

    def wechat_mp_login_state
      get('wechat_mp_login_state')
    end

    def wechat_mp_login_state=(val)
      set('wechat_mp_login_state', val)
    end

    def wechat_mp_account_info
      get('wechat_mp_account_info')
    end

    def wechat_mp_account_info=(val)
      set('wechat_mp_account_info', val)
    end

    # 有效期的中文文案，视图与飞书文案共用，避免各处再硬编码一份数字
    def wechat_mp_session_ttl_label
      ttl = WECHAT_MP_SESSION_TTL
      ttl < 1.day ? "约 #{(ttl / 1.hour).to_i} 小时" : "约 #{(ttl / 1.day).to_i} 天"
    end

    # 扫码登录成功后一次性写入整套会话字段（含按 WECHAT_MP_SESSION_TTL 计算的过期时间）。
    # api_client 只负责拿到凭据，落库统一走这里。
    def wechat_mp_session_started!(cookie:, token:, account_info: {})
      transaction do
        self.wechat_mp_cookie = cookie
        self.wechat_mp_token = token
        self.wechat_mp_login_state = "success"
        self.wechat_mp_expires_at = (Time.current + WECHAT_MP_SESSION_TTL).iso8601
        self.wechat_mp_account_info = account_info.to_json
      end
    end

    # 退出登录 / 会话作废时清空整套字段
    def wechat_mp_session_cleared!
      transaction do
        self.wechat_mp_cookie = nil
        self.wechat_mp_token = nil
        self.wechat_mp_login_state = nil
        self.wechat_mp_expires_at = nil
        self.wechat_mp_account_info = nil
      end
    end

    def wechat_mp_session_valid?
      cookie = wechat_mp_cookie
      token = wechat_mp_token
      return false if cookie.blank? || token.blank?

      expires_at = wechat_mp_expires_at
      return true if expires_at.blank?
      Time.parse(expires_at).future? rescue false
    end

    # ── OpenAI / LLM 配置（Website Monitor 语义分析）─────
    # 通过 MiraclePlus OpenAI 代理调用 Responses API。密钥仅存于 Option，
    # 切勿硬编码到代码中。见 LlmClient。
    OPENAI_DEFAULT_PROXY_URL = "https://openai-proxy.miracleplus.com/v1"
    OPENAI_DEFAULT_MODEL = "openai/gpt-5.2"

    def openai_api_key
      get("openai_api_key")
    end

    def openai_api_key=(val)
      set("openai_api_key", val)
    end

    def openai_api_key_valid?
      openai_api_key.present?
    end

    def openai_model
      get("openai_model").presence || OPENAI_DEFAULT_MODEL
    end

    def openai_model=(val)
      set("openai_model", val)
    end

    def openai_proxy_url
      get("openai_proxy_url").presence || OPENAI_DEFAULT_PROXY_URL
    end

    def openai_proxy_url=(val)
      set("openai_proxy_url", val)
    end

    # Per-platform crawl toggle helpers
    def crawl_wechat_enabled?
      get("crawl_wechat_enabled") != "false"
    end

    def crawl_rednote_enabled?
      get("crawl_rednote_enabled") != "false"
    end

    def crawl_twitter_enabled?
      get("crawl_twitter_enabled") != "false"
    end

    def crawl_website_enabled?
      get("crawl_website_enabled") != "false"
    end

    # Profile Ext credential helpers
    CREDENTIAL_LIVE_MINUTES = 25

    def profile_ext_credentials
      get('profile_ext_credentials')
    end

    def profile_ext_credentials=(val)
      set('profile_ext_credentials', val)
      set('profile_ext_credentials_updated_at', Time.current.iso8601)
    end

    def profile_ext_credentials_updated_at
      get('profile_ext_credentials_updated_at')
    end

    def profile_ext_credentials_valid?
      creds = profile_ext_credentials
      return false unless creds.present?
      !profile_ext_credentials_expired?
    end

    def profile_ext_credentials_expired?
      age = profile_ext_credentials_age_minutes
      return true unless age
      age >= CREDENTIAL_LIVE_MINUTES
    end

    # ── WeRead (微信读书) 转发服务配置 ──────────────────

    def weread_platform_url
      get("weread_platform_url") || "https://weread.111965.xyz"
    end

    def weread_platform_url=(val)
      set("weread_platform_url", val)
    end

    # WeRead 账号列表: JSON 数组 [{vid, token, name, status}]
    # status: 0=失效, 1=启用, 2=禁用
    def weread_accounts
      raw = get("weread_accounts")
      return [] if raw.blank?
      JSON.parse(raw)
    rescue JSON::ParserError
      []
    end

    def weread_accounts=(val)
      set("weread_accounts", val.is_a?(String) ? val : val.to_json)
    end

    # 当日黑名单: JSON 对象 { "YYYY-MM-DD" => ["vid1", "vid2"] }
    def weread_blocked_accounts
      raw = get("weread_blocked_accounts")
      return {} if raw.blank?
      JSON.parse(raw)
    rescue JSON::ParserError
      {}
    end

    def weread_blocked_accounts=(val)
      set("weread_blocked_accounts", val.is_a?(String) ? val : val.to_json)
    end

    def weread_accounts_valid?
      weread_accounts.any? { |a| a["status"].to_i == 1 }
    end

    # ── WeRead Native (直连 weread.qq.com) 扫码登录会话 ──
    #
    # 与 mp_native 会话同构：扫码登录成功后写入一套 Cookie（wr_vid / wr_skey ...），
    # 单会话槽位。TTL 仅为本地时间戳启发式，真正权威是 WereadNativeApiClient.validate_key
    # 的实时探测（每日由 FeishuLoginReminderJob 体检）。
    WEREAD_NATIVE_SESSION_TTL = 2.hours

    # Cookie 以 JSON 对象（name => value）持久化
    def weread_native_cookie
      get("weread_native_cookie")
    end

    def weread_native_cookie=(val)
      set("weread_native_cookie", val)
    end

    def weread_native_cookie_jar
      raw = weread_native_cookie
      return {} if raw.blank?
      JSON.parse(raw)
    rescue JSON::ParserError
      {}
    end

    def weread_native_expires_at
      get("weread_native_expires_at")
    end

    def weread_native_expires_at=(val)
      set("weread_native_expires_at", val)
    end

    def weread_native_login_state
      get("weread_native_login_state")
    end

    def weread_native_login_state=(val)
      set("weread_native_login_state", val)
    end

    def weread_native_account_info
      get("weread_native_account_info")
    end

    def weread_native_account_info=(val)
      set("weread_native_account_info", val)
    end

    def weread_native_session_ttl_label
      ttl = WEREAD_NATIVE_SESSION_TTL
      ttl < 1.day ? "约 #{(ttl / 1.hour).to_i} 小时" : "约 #{(ttl / 1.day).to_i} 天"
    end

    # 扫码登录成功后一次性写入整套会话字段（cookie_jar 为 name => value 的 Hash）
    def weread_native_session_started!(cookie_jar:, account_info: {})
      transaction do
        self.weread_native_cookie = cookie_jar.is_a?(String) ? cookie_jar : cookie_jar.to_json
        self.weread_native_login_state = "success"
        self.weread_native_expires_at = (Time.current + WEREAD_NATIVE_SESSION_TTL).iso8601
        self.weread_native_account_info = account_info.to_json
      end
    end

    def weread_native_session_cleared!
      transaction do
        self.weread_native_cookie = nil
        self.weread_native_login_state = nil
        self.weread_native_expires_at = nil
        self.weread_native_account_info = nil
      end
    end

    def weread_native_session_valid?
      return false if weread_native_cookie_jar.empty?

      expires_at = weread_native_expires_at
      return true if expires_at.blank?
      Time.parse(expires_at).future? rescue false
    end

    # ── Feishu (飞书) 推送配置 ──────────────────────────
    # 用于每日推送微信读书登录二维码到飞书（私聊/群）。

    def feishu_enabled?
      get("feishu_enabled") != "false"
    end

    def feishu_app_id
      get("feishu_app_id")
    end

    def feishu_app_id=(val)
      set("feishu_app_id", val)
    end

    def feishu_app_secret
      get("feishu_app_secret")
    end

    def feishu_app_secret=(val)
      set("feishu_app_secret", val)
    end

    # 推送目标 ID：私聊为 open_id，群为 chat_id
    def feishu_receive_id
      get("feishu_receive_id")
    end

    def feishu_receive_id=(val)
      set("feishu_receive_id", val)
    end

    # "open_id"（私聊）或 "chat_id"（群），默认 open_id
    def feishu_receive_id_type
      get("feishu_receive_id_type") || "open_id"
    end

    def feishu_receive_id_type=(val)
      set("feishu_receive_id_type", val)
    end

    def feishu_encrypt_key
      get("feishu_encrypt_key")
    end

    def feishu_encrypt_key=(val)
      set("feishu_encrypt_key", val)
    end

    # 飞书扫码登录推送方式，微信读书与微信公众号平台共用：
    #   qr（推一张二维码到目标会话，默认）/ card（发交互卡片，成员点击后私聊各自二维码）
    # 读取时回退到旧 key feishu_weread_login_mode，历史配置无需迁移。
    def feishu_login_mode
      get("feishu_login_mode") || get("feishu_weread_login_mode") || "qr"
    end

    def feishu_login_mode=(val)
      set("feishu_login_mode", val)
    end

    def feishu_login_card_mode?
      feishu_login_mode == "card"
    end

    def profile_ext_credentials_age_minutes
      # 优先用 credentials.json 内部的 timestamp（毫秒时间戳）
      raw = profile_ext_credentials
      if raw.present?
        cred = JSON.parse(raw) rescue nil
        ts = cred&.dig('timestamp') if cred.is_a?(Hash)
        ts = cred.first&.dig('timestamp') if cred.is_a?(Array)
        if ts
          captured_at = Time.at(ts.to_f / 1000)
          return ((Time.current - captured_at) / 60.0).round(1)
        end
      end

      # fallback: Option 存储时间
      updated_at = profile_ext_credentials_updated_at
      return nil unless updated_at
      ((Time.current - Time.parse(updated_at)) / 60.0).round(1)
    rescue StandardError
      nil
    end
  end
end
