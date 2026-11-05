require "fileutils"

class DailyReportMarkdownStore
  def self.write!(report)
    raise ArgumentError, "日报正文不能为空" if report.markdown_content.blank?

    directory = Rails.root.join("storage", "daily_reports", report.report_date.iso8601)
    FileUtils.mkdir_p(directory)
    path = directory.join("report.md")
    temporary = directory.join(".report-#{SecureRandom.hex(12)}.tmp")
    begin
      File.write(temporary, report.markdown_content, mode: "w", encoding: "UTF-8")
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if File.exist?(temporary)
    end
    path.to_s
  end
end
