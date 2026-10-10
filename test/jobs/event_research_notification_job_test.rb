require "test_helper"

class EventResearchNotificationJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = EventAccount.create!(nickname: "测试大会", fakeid: "event:notification-test", event_config: { feishu_chat_id: "oc_test" })
    @run = EventResearchRun.create!(account: @account, status: :completed, completed_at: Time.current, result: result("张三", "甲公司"))
    @sent = []
  end

  test "首轮发送完整结果并记录 sent" do
    sent = []
    stub_class_methods(FeishuNotifier, enabled?: -> { true }, send_text: ->(text, **kwargs) { sent << [ text, kwargs ] }) do
      EventResearchNotificationJob.perform_now(@run.id)
    end

    notification = EventResearchNotification.find_by!(event_research_run: @run)
    assert notification.initial?
    assert notification.sent?
    assert_match "完整研究结果", notification.payload_text
    assert_match "奖项/项目", notification.payload_text
    refute_match "query:", notification.payload_text
    assert_match research_url(@run), notification.payload_text
    assert_equal notification.payload_text, sent.first.first
    assert_equal "oc_test", sent.first.last[:receive_id]
    assert_equal "chat_id", sent.first.last[:receive_id_type]
  end

  test "飞书发送失败不推进基线" do
    stub_class_methods(FeishuNotifier, enabled?: -> { true }, send_text: ->(*) { raise FeishuNotifier::Error, "发送失败" }) do
      assert_nothing_raised { EventResearchNotificationJob.perform_now(@run.id) }
    end

    assert EventResearchNotification.find_by!(event_research_run: @run).failed?
    assert_match "完整研究结果", EventResearchNotification.find_by!(event_research_run: @run).payload_text
    assert_nil EventResearchNotification.last_sent_baseline_for(@account)
  end

  test "第二轮只发送新增信息并以首轮为基线" do
    sent = []
    stub_class_methods(FeishuNotifier, enabled?: -> { true }, send_text: ->(text, **kwargs) { sent << [ text, kwargs ] }) do
      EventResearchNotificationJob.perform_now(@run.id)
      second = EventResearchRun.create!(account: @account, status: :completed, completed_at: Time.current, result: result("张三", "乙公司"))
      EventResearchNotificationJob.perform_now(second.id)
    end

    assert_equal 2, sent.length
    assert_match "乙公司", sent.last.first
    refute_match "甲公司", sent.last.first
    second = EventResearchRun.order(:id).last
    weekly = EventResearchNotification.find_by!(event_research_run: second)
    assert weekly.weekly?
    assert_match "乙公司", weekly.payload_text
    assert_match research_url(second), weekly.payload_text
    refute_match research_url(@run), weekly.payload_text
  end

  test "管理员重推复用原正文且不创建新通知" do
    sent = []
    stub_class_methods(FeishuNotifier, enabled?: -> { true }, send_text: ->(text, **kwargs) { sent << [ text, kwargs ] }) do
      EventResearchNotificationJob.perform_now(@run.id)
      notification = EventResearchNotification.find_by!(event_research_run: @run)
      notification.update!(payload_text: "原始历史正文", status: :sent)
      EventResearchNotificationJob.perform_now(@run.id, notification_id: notification.id, force: true)
    end

    assert_equal 2, sent.length
    assert_equal "原始历史正文", sent.last.first
    assert_equal 1, EventResearchNotification.where(event_research_run: @run).count
    assert EventResearchNotification.find_by!(event_research_run: @run).sent?
  end

  private

  def research_url(run)
    Rails.application.routes.url_helpers.event_account_url(
      @account,
      run_id: run.id,
      host: "localhost",
      port: 3000,
      protocol: "http"
    )
  end

  def result(person, company)
    { "event" => { "name" => "测试大会" }, "awards" => [ { "rank" => "一等奖", "people" => [ { "name" => person } ] } ], "companies" => [ { "name" => company } ] }
  end
end
