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

    # Wechat API key helpers
    def api_key
      get('wechat_api_key')
    end

    def api_key=(val)
      set('wechat_api_key', val)
    end

    def api_key_valid?
      key = api_key
      key.present? && !api_key_expired?
    end

    def api_key_expired?
      expires_at = get('wechat_api_key_expires_at')
      return false if expires_at.blank?
      Time.parse(expires_at).past? rescue false
    end

    def api_key_expires_soon?
      expires_at = get('wechat_api_key_expires_at')
      return false if expires_at.blank?
      time = Time.parse(expires_at) rescue nil
      time.present? && time < 24.hours.from_now
    end

    def default_article_concurrency
      (get('default_article_concurrency') || 10).to_i
    end

    def default_account_concurrency
      (get('default_account_concurrency') || 3).to_i
    end

    def max_crawl_pages
      (get('max_crawl_pages') || -1).to_i
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
  end
end
