class DailyReportJob < ApplicationJob
  queue_as :default

  def perform(report_date = Date.current.yesterday)
    date = report_date.to_date
    zone = Time.zone
    report = DailyReport.find_or_initialize_by(report_date: date)
    report.window_start ||= zone.local(date.year, date.month, date.day)
    report.window_end ||= zone.local(date.year, date.month, date.day) + 1.day
    report.save! if report.new_record?
    return report if report.completed?

    report.update!(status: :running, error_message: nil)
    report.update!(sections: DailyReportGenerator.new.call(report), status: :completed)
  rescue StandardError => e
    report&.update(status: :failed, error_message: e.message.to_s.truncate(2_000))
    Rails.logger.error("[DailyReportJob] #{date}: #{e.class}: #{e.message}")
    raise
  end
end
