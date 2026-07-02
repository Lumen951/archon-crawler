class CrawlLog < ApplicationRecord
  belongs_to :crawl_task, touch: true

  LEVELS = %w[debug info warn error].freeze

  validates :level, inclusion: { in: LEVELS }

  scope :recent, -> { order(logged_at: :desc) }
  scope :by_level, ->(level) { where(level: level) }
  scope :errors, -> { where(level: 'error') }
  scope :warnings, -> { where(level: 'warn') }

  def self.log(crawl_task, level, message, context: nil)
    return unless Option.verbose_mode?

    create!(
      crawl_task: crawl_task,
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
