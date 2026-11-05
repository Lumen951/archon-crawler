class DailyReportJob < ApplicationJob
  queue_as :default

  def perform(report_date = Time.current.in_time_zone("Beijing").to_date.yesterday)
    date = report_date.to_date
    DailyReport.connection_pool.with_connection do |connection|
      key = connection.quote("daily-report:#{date.iso8601}")
      return unless connection.select_value("SELECT pg_try_advisory_lock(hashtextextended(#{key}, 0))")

      begin
        generate_report(date)
      ensure
        connection.execute("SELECT pg_advisory_unlock(hashtextextended(#{key}, 0))")
      end
    end
  end

  private

  def generate_report(date)
    zone = ActiveSupport::TimeZone["Beijing"]
    report = DailyReport.find_or_initialize_by(report_date: date)
    report.window_start ||= zone.local(date.year, date.month, date.day)
    report.window_end ||= report.window_start + 1.day
    report.save! if report.new_record?

    # A persisted body can be published again without another paid LLM request.
    if report.markdown_content.blank? && report.completed? && report.readable_markdown.present?
      report.update!(markdown_content: report.readable_markdown)
    end
    if report.markdown_content.blank?
      report.update!(status: :running, error_message: nil)
      report.update!(markdown_content: DailyReportGenerator.new.call(report))
    end
    DailyReportMarkdownStore.write!(report)
    report.update!(status: :completed, error_message: nil)
    report
  rescue StandardError => e
    message = e.is_a?(LlmClient::ApiKeyMissingError) ? "请先在个人资料中添加 LLM API 密钥" : "日报生成或保存失败，请联系管理员检查（#{e.class.name}）"
    report&.update(status: :failed, error_message: message)
    Rails.logger.error("[DailyReportJob] #{date}: #{e.class.name}")
    raise DailyReportGenerator::GenerationError, message, cause: nil
  end
end
