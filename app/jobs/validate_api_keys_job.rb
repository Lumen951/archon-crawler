class ValidateApiKeysJob < ApplicationJob
  queue_as :default

  def perform
    expired_keys = []

    unless WechatApiClient.validate_key
      expired_keys << :wechat
      Rails.logger.warn "[ValidateApiKeysJob] WeChat API key is invalid or expired"
    end

    unless RednoteApiClient.validate_key
      expired_keys << :rednote
      Rails.logger.warn "[ValidateApiKeysJob] Rednote API key is invalid or expired"
    end

    return if expired_keys.empty?

    notify_admins(expired_keys)
  end

  private

  def notify_admins(expired_keys)
    return if Rails.cache.read("api_key_expiry_last_notified_at")&.after?(24.hours.ago)

    admins = User.where(role: :admin).select(&:notify_api_key_expiry?)
    admins.each do |admin|
      AdminMailer.api_key_expired(admin, expired_keys).deliver_later
    end

    Rails.cache.write("api_key_expiry_last_notified_at", Time.current, expires_in: 48.hours)
  end
end
