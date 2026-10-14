require "test_helper"

class EventWeeklyDigestJobTest < ActiveSupport::TestCase
  setup do
    @account = EventAccount.create!(nickname: "测试大会", fakeid: "event:digest-job")
  end

  test "手动任务结束后生成站内研究报告但不自动推送" do
    task = completed_task(source: :manual_single)

    assert_difference -> { EventWeeklyDigest.count }, 1 do
      EventWeeklyDigestJob.perform_now(task.id, auto_send: false)
    end
    report = EventWeeklyDigest.find_by!(event_research_task: task)
    assert report.skipped?
    assert_match "手动研究任务", report.error_message
    assert_equal @account.id, report.sections.fetch("events").sole.fetch("account_id")
  end

  test "定时任务结束后生成报告并推送到默认活动目标" do
    Option.event_feishu_receive_id = "oc_digest"
    task = completed_task(source: :scheduled)
    sent = []

    stub_class_methods(FeishuNotifier, send_card: ->(card, **kwargs) { sent << [ card, kwargs ] }) do
      EventWeeklyDigestJob.perform_now(task.id, auto_send: true)
    end

    report = EventWeeklyDigest.find_by!(event_research_task: task)
    assert report.sent?
    assert_match "活动研究报告", report.payload_text
    assert_equal "oc_digest", sent.sole.last.fetch(:receive_id)
    assert_equal "blue", sent.sole.first.dig(:header, :template)
    assert_match "**", sent.sole.first.dig(:elements, 0, :text, :content)
  end

  test "失败与跳过成员会保留在任务报告内" do
    task = EventResearchTask.create_for!([ @account ], source: :manual_single)
    item = task.event_research_task_accounts.sole
    item.mark_skipped!("已有进行中的调研")
    task.update!(status: :completed, progress: 1, completed_at: Time.current)

    EventWeeklyDigestJob.perform_now(task.id, auto_send: false)

    event = EventWeeklyDigest.find_by!(event_research_task: task).sections.fetch("events").sole
    assert_match "跳过", event.fetch("note")
  end

  private

  def completed_task(source:)
    task = EventResearchTask.create_for!([ @account ], source: source)
    run = EventResearchRun.create!(account: @account, status: :completed, completed_at: Time.current, result: sample_result, people_count: 1)
    task.event_research_task_accounts.sole.update!(event_research_run: run, status: :completed, completed_at: Time.current)
    task.update!(status: :completed, progress: 1, completed_at: Time.current)
    task
  end

  def sample_result
    {
      "event" => { "name" => "测试大会" }, "awards" => [], "companies" => [],
      "intelligence" => {
        "people" => [ { "name" => "张三", "role_or_title" => "创始人", "company" => "甲公司", "project" => "项目", "evidence" => [ { "quote" => "张三创办甲公司" } ], "confidence" => "high" } ],
        "projects" => [], "companies" => [], "awards" => [], "contacts" => []
      }
    }
  end
end
