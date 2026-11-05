class DailyReport < ApplicationRecord
  enum :status, { pending: 0, running: 1, completed: 2, failed: 3 }

  validates :report_date, :window_start, :window_end, presence: true
  validates :report_date, uniqueness: true
  validate :window_must_be_ordered

  scope :recent, -> { order(report_date: :desc) }

  def title
    "#{report_date.strftime('%Y年%m月%d日')} 每日简报"
  end

  def markdown_path
    Rails.root.join("storage", "daily_reports", report_date.iso8601, "report.md")
  end

  def readable_markdown
    return markdown_content if markdown_content.present?

    Array(sections.is_a?(Hash) ? sections["items"] : []).filter_map do |item|
      next unless item.is_a?(Hash)

      lines = [ "## #{item['title']}" ]
      item.except("title", "source_type", "source_id", "kind", "url").each do |label, value|
        lines << "#{label}：#{value}" if value.present?
      end
      lines << "来源：#{item['url']}" if item["url"].present?
      lines.join("\n\n")
    end.join("\n\n")
  end

  private

  def window_must_be_ordered
    return if window_start.blank? || window_end.blank? || window_start < window_end

    errors.add(:window_end, "必须晚于开始时间")
  end
end
