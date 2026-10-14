require "test_helper"

class EventWeeklyDigestResendJobTest < ActiveSupport::TestCase
  setup do
    Option.event_feishu_receive_id = "oc_resend"
    @digest = EventWeeklyDigest.create!(week_start: Date.current.beginning_of_week, payload_text: "保存的旧报告")
  end

  test "重发使用卡片而不重新聚合研究" do
    sent = []
    stub_class_methods(EventResearch::WeeklyDigestBuilder, call: ->(*) { flunk "不应重新聚合" }) do
      stub_class_methods(FeishuNotifier, send_card: ->(card, **target) { sent << [ card, target ] }) do
        EventWeeklyDigestResendJob.perform_now(@digest.id)
      end
    end
    assert @digest.reload.sent?
    assert_equal "oc_resend", sent.sole.last[:receive_id]
    assert_match "保存的旧报告", sent.sole.first.to_json
  end

  test "发送错误保留旧发送时间并记录失败" do
    @digest.update!(sent_at: 1.day.ago)
    sent_at = @digest.sent_at
    stub_class_methods(FeishuNotifier, send_card: ->(*) { raise FeishuNotifier::Error, "推送失败" }) do
      EventWeeklyDigestResendJob.perform_now(@digest.id)
    end
    assert @digest.reload.failed?
    assert_equal sent_at, @digest.sent_at
    assert_equal "推送失败", @digest.error_message
  end

  test "缺少目标跳过发送" do
    Option.event_feishu_receive_id = nil
    EventWeeklyDigestResendJob.perform_now(@digest.id)
    assert @digest.reload.skipped?
  end
end
