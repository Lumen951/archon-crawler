require "test_helper"

class EventWeeklyDigestRegenerationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "重新生成只用任务关联运行且保留投递字段" do
    account = EventAccount.create!(nickname: "保存的活动", fakeid: "event:regeneration-model")
    task = EventResearchTask.create_for!([ account ], source: :manual_single)
    run = EventResearchRun.create!(account: account, status: :completed, completed_at: Time.current,
      result: { "metadata" => { "cache" => { "search" => { "miss" => 3, "hit" => 2 } } } })
    EventResearchRun.create!(account: account, status: :completed, completed_at: 1.minute.from_now,
      result: { "metadata" => { "cache" => { "search" => { "miss" => 99 } } } })
    task.event_research_task_accounts.sole.update!(event_research_run: run, status: :completed)
    task.update!(status: :failed)
    digest = EventWeeklyDigest.create!(event_research_task: task, week_start: Date.current.beginning_of_week,
      status: :failed, sent_at: 1.day.ago, error_message: "之前发送失败", payload_text: "旧内容")
    before = digest.attributes.slice("id", "week_start", "status", "sent_at", "error_message", "event_research_task_id")

    assert_no_difference -> { EventResearchRun.count } do
      assert_no_enqueued_jobs { digest.regenerate! }
    end

    assert_equal before, digest.reload.attributes.slice(*before.keys)
    assert_equal 3, digest.sections.dig("api_usage", "search", "api_calls")
    assert_match "搜索 API 3", digest.payload_text
  end

  test "非终态任务不允许覆盖报告" do
    account = EventAccount.create!(nickname: "运行中活动", fakeid: "event:regeneration-pending")
    task = EventResearchTask.create_for!([ account ], source: :manual_single)
    digest = EventWeeklyDigest.create!(event_research_task: task, week_start: Date.current.beginning_of_week, payload_text: "旧内容")

    assert_raises(EventWeeklyDigest::RegenerationUnavailable) { digest.regenerate! }
    assert_equal "旧内容", digest.reload.payload_text
  end

  test "旧报告从已保存 sections 重新排版" do
    digest = EventWeeklyDigest.create!(week_start: Date.current.beginning_of_week, payload_text: "旧内容", sections: { "summary" => { "people" => 7 } })

    digest.regenerate!

    assert_equal 7, digest.reload.sections.dig("summary", "people")
    assert_match "重点人脉 7 位", digest.payload_text
  end

  test "渲染失败时数据库内容不变" do
    digest = EventWeeklyDigest.create!(week_start: Date.current.beginning_of_week, payload_text: "旧内容", sections: { "summary" => { "people" => 7 } })
    stub_class_methods(EventResearch::WeeklyDigestText, call: ->(*) { raise "渲染失败" }) do
      assert_raises(RuntimeError) { digest.regenerate! }
    end
    assert_equal "旧内容", digest.reload.payload_text
  end
end
