class SystemConfig < ApplicationRecord
  validates :key, presence: true, uniqueness: true

  def self.get(key)
    find_by(key: key)&.value
  end

  def self.set(key, value, expires_at: nil)
    config = find_or_initialize_by(key: key)
    config.value = value
    config.expires_at = expires_at
    config.save!
    config
  end

  def self.api_key
    get('wechat_api_key')
  end

  def self.api_key_valid?
    config = find_by(key: 'wechat_api_key')
    return false unless config&.value.present?
    return true if config.expires_at.nil?

    config.expires_at > Time.current
  end

  def self.api_key_expires_soon?
    config = find_by(key: 'wechat_api_key')
    return false unless config&.expires_at

    config.expires_at < 24.hours.from_now
  end

  def self.default_article_concurrency
    get('default_article_concurrency')&.to_i || 10
  end

  def self.default_account_concurrency
    get('default_account_concurrency')&.to_i || 5
  end

  def self.max_crawl_pages
    get('max_crawl_pages')&.to_i || 1
  end
end
