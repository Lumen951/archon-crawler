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
      markdown_content: "# 每日研究简报\n\n## 机器人研究\n\n研究摘要"
    )
  end

  test "index lists reports" do
    get daily_reports_path

    assert_response :success
    assert_match "每日简报", response.body
    assert_match @report.title, response.body
  end

  test "report content escapes model HTML" do
    @report.update!(markdown_content: "# <script>alert(1)</script>\n\n<img src=x onerror=alert(1)>")
    get daily_report_path(@report)
    assert_response :success
    assert_select "article script", count: 0
    assert_select "article img", count: 0
    assert_select "article h1", text: "<script>alert(1)</script>"
  end

  test "legacy JSON reports remain readable" do
    @report.update!(markdown_content: nil, sections: { "items" => [ { "title" => "历史技术报告", "summary" => "历史摘要" } ] })
    get daily_report_path(@report)
    assert_response :success
    assert_select "article h2", text: "历史技术报告"
    assert_includes response.body, "历史摘要"
  end

  test "anonymous users cannot read reports" do
    delete session_path
    get daily_report_path(@report)
    assert_response :redirect
  end

  test "show renders technical summary" do
    get daily_report_path(@report)

    assert_response :success
    assert_match "机器人研究", response.body
    assert_match "研究摘要", response.body
  end
end
