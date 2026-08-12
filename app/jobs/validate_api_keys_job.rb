class ValidateApiKeysJob < ApplicationJob
  queue_as :default

  def perform
    expired_keys = []

    wechat_valid = WechatMpNativeApiClient.validate_key
    result = { valid: wechat_valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:wechat', result, expires_in: 2.hours)
    unless wechat_valid
      expired_keys << :wechat
      Rails.logger.warn "[ValidateApiKeysJob] MP Native session is invalid or expired"
    end

    rednote_valid = RednoteApiClient.validate_key
    result = { valid: rednote_valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:rednote', result, expires_in: 2.hours)
    unless rednote_valid
      expired_keys << :rednote
      Rails.logger.warn "[ValidateApiKeysJob] Rednote API key is invalid or expired"
    end
    
    twitter_valid = TwitterApiClient.validate_key
    result = { valid: twitter_valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:twitter', result, expires_in: 2.hours)
    unless twitter_valid
      expired_keys << :twitter
      Rails.logger.warn "[ValidateApiKeysJob] Twitter API key is invalid or expired"
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
