# == Schema Information
#
# Table name: crawl_logs
#
#  id            :bigint           not null, primary key
#  context       :text
#  level         :string           not null
#  loggable_type :string
#  logged_at     :datetime
#  message       :text
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  loggable_id   :bigint
#
# Indexes
#
#  index_crawl_logs_on_level                          (level)
#  index_crawl_logs_on_loggable_type_and_loggable_id  (loggable_type,loggable_id)
#  index_crawl_logs_on_logged_at                      (logged_at)
#
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
