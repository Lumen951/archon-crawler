class DailyReport < ApplicationRecord
  enum :status, { pending: 0, running: 1, completed: 2, failed: 3 }

  validates :report_date, :window_start, :window_end, presence: true
  validates :report_date, uniqueness: true
  validate :window_must_be_ordered

  scope :recent, -> { order(report_date: :desc) }

  def title
    "#{report_date.strftime('%Y年%m月%d日')} 每日简报"
  end

  private

  def window_must_be_ordered
    return if window_start.blank? || window_end.blank? || window_start < window_end

    errors.add(:window_end, "必须晚于开始时间")
  end
end
