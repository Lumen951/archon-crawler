require "test_helper"

class DailyReportTest < ActiveSupport::TestCase
  test "日期必须唯一且时间窗口有效" do
    report = DailyReport.create!(
      report_date: Date.new(2026, 11, 2),
      window_start: Time.zone.local(2026, 11, 2),
      window_end: Time.zone.local(2026, 11, 3)
    )

    duplicate = DailyReport.new(
      report_date: report.report_date,
      window_start: report.window_start,
      window_end: report.window_end
    )
    refute duplicate.valid?
    assert_includes duplicate.errors.attribute_names, :report_date

    invalid_window = DailyReport.new(
      report_date: Date.new(2026, 11, 3),
      window_start: Time.zone.local(2026, 11, 4),
      window_end: Time.zone.local(2026, 11, 3)
    )
    refute invalid_window.valid?
    assert_includes invalid_window.errors.attribute_names, :window_end
  end
end
