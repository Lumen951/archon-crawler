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
  # ── OpenAI / LLM 配置（Website Monitor 语义分析）─────
  # 通过 MiraclePlus OpenAI 代理调用 Responses API。密钥仅存于 Option，
  # 切勿硬编码到代码中。见 LlmClient。
  OPENAI_DEFAULT_PROXY_URL = "https://openai-proxy.miracleplus.com/v1"
  OPENAI_DEFAULT_MODEL = "gpt-5.4"

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

    # Tianyancha API key helpers (企业工商信息，供活动调研补全机构档案)
    def tianyancha_api_key
      get('tianyancha_api_key')
    end

    def tianyancha_api_key=(val)
      set('tianyancha_api_key', val)
    end

    def tianyancha_api_key_valid?
      tianyancha_api_key.present?
    end

    # Serper (Google Search) API key helpers（活动调研的搜索数据源）
    def serper_api_key
      get('serper_api_key')
    end

    def serper_api_key=(val)
      set('serper_api_key', val)
    end

    def serper_api_key_valid?
      serper_api_key.present?
    end

    # WeChat API provider helpers
    def wechat_api_provider
      # 2026-10：mp.weixin.qq.com 直连系 provider（mp_native / dajiala / profile_ext）
      # 与 weread 转发账号池已基本不可用，抓取统一切换到 weread_native（直连微信读书）。
      # 历史库里遗留的旧值一并按 weread_native 处理——否则生产库已存的 mp_native
      # 会让默认值改动不生效。如需恢复旧 provider，从这里改起。
      stored = get('wechat_api_provider')
      return 'weread_native' if stored.blank? || %w[mp_native dajiala profile_ext weread].include?(stored)

      stored
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

    # 正文下载被「当前环境异常，需要验证」拦截时，改用真实浏览器抓取
    # （WechatArticleBrowserFetcher，复用远程登录环境里的人工验证 Cookie）。
    # 默认开启（与其他 crawl_* 开关同约定：非 "false" 即开启）。
    def wechat_content_browser_fallback_enabled?
      get("wechat_content_browser_fallback") != "false"
    end

    # WeRead Native（直连）文章列表限流参数：请求数 / 窗口秒数（默认 30 次/60 秒）
    def weread_native_list_rate_limit
      (get('weread_native_list_rate_limit') || 30).to_i
    end

    def weread_native_list_rate_limit=(val)
      set('weread_native_list_rate_limit', val)
    end

    def weread_native_list_rate_window
      (get('weread_native_list_rate_window') || 60).to_i
    end

    def weread_native_list_rate_window=(val)
      set('weread_native_list_rate_window', val)
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

    # ── 官网列表抓取的渲染兜底（本地浏览器 / ScrapingAnt）────────
    # 只有一种情况会用到渲染兜底：直连 HTTP 拿到了响应，但 crawl_rule 一条内容都
    # 提取不出来（JS 渲染页面的典型特征），此时按配置的 provider 顺序依次尝试重新渲染。
    # 密钥仅存于 Option，切勿硬编码到代码中；未配置则只是没有这个兜底，其余抓取不受影响。
    # 见 WebsiteCrawler::RenderFallbackChain / LocalHeadlessBrowserFetcher / ScrapingAntFetcher。

    # 可用的渲染兜底 provider（顺序敏感：推荐本地优先，ScrapingAnt 兜底）
    WEBSITE_RENDER_FALLBACK_PROVIDERS = %w[local_headless scrapingant].freeze
    WEBSITE_RENDER_FALLBACKS_DEFAULT = %w[local_headless scrapingant].freeze

    def scrapingant_api_key
      get("scrapingant_api_key")
    end

    def scrapingant_api_key=(val)
      set("scrapingant_api_key", val)
    end

    # 渲染兜底 provider 配置：返回归一化的 provider 列表（去重、过滤非法值、保留顺序）
    def website_render_fallbacks
      raw = get("website_render_fallbacks")
      # 支持 JSON 数组或逗号分隔字符串
      list = if raw.present?
        if raw.start_with?("[")
          begin
            JSON.parse(raw)
          rescue JSON::ParserError
            []
          end
        else
          raw.split(",").map(&:strip)
        end
      else
        WEBSITE_RENDER_FALLBACKS_DEFAULT
      end
      # 归一化：只保留已知 provider，去重，保留用户指定的顺序
      list.map(&:to_s).select { |p| WEBSITE_RENDER_FALLBACK_PROVIDERS.include?(p) }.uniq
    end

    def website_render_fallbacks=(val)
      # 接受数组或逗号分隔字符串
      normalized = case val
      when Array
        val.map(&:to_s).select { |p| WEBSITE_RENDER_FALLBACK_PROVIDERS.include?(p) }.uniq
      when String
        val.split(",").map(&:strip).select { |p| WEBSITE_RENDER_FALLBACK_PROVIDERS.include?(p) }.uniq
      else
        []
      end
      set("website_render_fallbacks", normalized.to_json)
    end

    def website_render_fallback_local_enabled?
      website_render_fallbacks.include?("local_headless")
    end

    def website_render_fallback_scrapingant_enabled?
      website_render_fallbacks.include?("scrapingant")
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

    # ── 小红书网页版（xiaohongshu.com）Cookie 会话 ──
    #
    # 与 mp_native / weread_native 同构：通过远程浏览器登录后写入一套 Cookie，
    # 单会话槽位。TTL 仅为本地时间戳启发式（小红书 web_session 通常可用数月），
    # 真正的会话状态以浏览器内重新登录为准。当前抓取走 RednoteApiClient/TikHub
    # 付费 API；这份 Cookie 是为后续直连抓取预留的凭据。
    REDNOTE_WEB_SESSION_TTL = 30.days

    def rednote_web_cookie
      get("rednote_web_cookie")
    end

    def rednote_web_cookie=(val)
      set("rednote_web_cookie", val)
    end

    def rednote_web_expires_at
      get("rednote_web_expires_at")
    end

    def rednote_web_expires_at=(val)
      set("rednote_web_expires_at", val)
    end

    def rednote_web_login_state
      get("rednote_web_login_state")
    end

    def rednote_web_login_state=(val)
      set("rednote_web_login_state", val)
    end

    def rednote_web_account_info
      get("rednote_web_account_info")
    end

    def rednote_web_account_info=(val)
      set("rednote_web_account_info", val)
    end

    def rednote_web_session_ttl_label
      ttl = REDNOTE_WEB_SESSION_TTL
      ttl < 1.day ? "约 #{(ttl / 1.hour).to_i} 小时" : "约 #{(ttl / 1.day).to_i} 天"
    end

    # 浏览器登录成功后一次性写入整套会话字段（cookie 为 "k=v; k2=v2" 头字符串）
    def rednote_web_session_started!(cookie:, account_info: {})
      transaction do
        self.rednote_web_cookie = cookie
        self.rednote_web_login_state = "success"
        self.rednote_web_expires_at = (Time.current + REDNOTE_WEB_SESSION_TTL).iso8601
        self.rednote_web_account_info = account_info.to_json
      end
    end

    def rednote_web_session_cleared!
      transaction do
        self.rednote_web_cookie = nil
        self.rednote_web_login_state = nil
        self.rednote_web_expires_at = nil
        self.rednote_web_account_info = nil
      end
    end

    def rednote_web_session_valid?
      return false if rednote_web_cookie.blank?

      expires_at = rednote_web_expires_at
      return true if expires_at.blank?
      Time.parse(expires_at).future? rescue false
    end

    # ── 远程浏览器登录（BrowserLogin）─────
    # true 时登录浏览器以有界面模式运行（Linux 下自动拉起 Xvfb 虚拟显示），
    # 对部分反爬页面更友好；默认 headless，无需 Xvfb。
    def browser_login_headed?
      get("browser_login_headed") == "true"
    end

    def browser_login_headed=(val)
      set("browser_login_headed", val == true || val == "true" || val == "1")
    end

    # 登录浏览器的代理（--proxy-server）。服务器机房 IP 常被小红书等平台的
    # 风控标记（错误码 300012），配置住宅/本地代理可绕开。支持
    # http://host:port 与 socks5://host:port；带账号密码的代理需先在本地
    # 转成无认证入口（Chrome 命令行不支持内联代理认证）。空 = 直连。
    def browser_login_proxy
      get("browser_login_proxy")
    end

    def browser_login_proxy=(val)
      set("browser_login_proxy", val)
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
