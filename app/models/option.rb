class Option < ApplicationRecord
  self.table_name = 'options'

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

    # Max accounts crawled per scheduled run (daily budget, anti-throttle cap).
    def daily_crawl_budget
      (get('daily_crawl_budget') || 200).to_i
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

    # WeChat 正文下载限流参数：请求数 / 窗口秒数（默认 5 次/60 秒，保守避免触发限流）
    def wechat_download_rate_limit
      (get('wechat_download_rate_limit') || 5).to_i
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

    def wechat_mp_session_valid?
      cookie = wechat_mp_cookie
      token = wechat_mp_token
      return false if cookie.blank? || token.blank?

      expires_at = wechat_mp_expires_at
      return true if expires_at.blank?
      Time.parse(expires_at).future? rescue false
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
