class CrawlLog < ApplicationRecord
  belongs_to :loggable, polymorphic: true

  LEVELS = %w[debug info warn error].freeze

  validates :level, inclusion: { in: LEVELS }

  scope :recent, -> { order(logged_at: :desc) }
  scope :by_level, ->(level) { where(level: level) }
  scope :errors, -> { where(level: 'error') }
  scope :warnings, -> { where(level: 'warn') }

  def self.log(loggable, level, message, context: nil)
    return unless Option.verbose_mode?

    create!(
      loggable: loggable,
      level: level.to_s,
      message: message,
      context: context&.to_json,
      logged_at: Time.current
    )
  rescue StandardError => e
    Rails.logger.error("Failed to create crawl log: #{e.message}")
  end

  def self.cleanup_old_logs
    retention_days = Option[:crawler_log_retention_days]
    where('logged_at < ?', retention_days.days.ago).delete_all
  end
end
