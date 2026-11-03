require "test_helper"

class DailyReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email_address: "daily-report@example.com",
      password: "password123",
      password_confirmation: "password123",
      email_confirmed_at: Time.current
    )
    post session_path, params: { email_address: @user.email_address, password: "password123" }
    @report = DailyReport.create!(
      report_date: Date.new(2026, 11, 2),
      window_start: Time.zone.local(2026, 11, 2),
      window_end: Time.zone.local(2026, 11, 3),
      status: :completed,
      sections: { "items" => [
        { "source_type" => "paper", "source_id" => 1, "kind" => "technical", "title" => "机器人研究", "summary" => "研究摘要" }
      ] }
    )
  end

  test "index lists reports" do
    get daily_reports_path

    assert_response :success
    assert_match "每日简报", response.body
    assert_match @report.title, response.body
  end

  test "show renders technical summary" do
    get daily_report_path(@report)

    assert_response :success
    assert_match "机器人研究", response.body
    assert_match "研究摘要", response.body
  end
end
