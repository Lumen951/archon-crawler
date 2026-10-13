require "test_helper"

class WeeklyEventResearchJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "只为启用持续研究的账号创建定时任务并强制忽略缓存" do
    enabled = EventAccount.create!(nickname: "启用活动", fakeid: "event:weekly-enabled", event_config: { weekly_research_enabled: true })
    EventAccount.create!(nickname: "停用活动", fakeid: "event:weekly-disabled", event_config: { weekly_research_enabled: false })

    assert_enqueued_with(job: EventResearchTaskJob) { WeeklyEventResearchJob.perform_now }

    task = EventResearchTask.sole
    assert task.scheduled?
    assert task.refresh_cache?
    assert_equal [ enabled.id ], task.event_research_task_accounts.pluck(:account_id)
  end

  test "重复触发同一调度周期只创建一个任务" do
    EventAccount.create!(nickname: "启用活动", fakeid: "event:weekly-duplicate", event_config: { weekly_research_enabled: true })

    WeeklyEventResearchJob.perform_now
    WeeklyEventResearchJob.perform_now

    assert_equal 1, EventResearchTask.scheduled.count
  end

  test "停用的账号即使开着周调研也不创建任务" do
    EventAccount.create!(nickname: "停用但开了周调研", fakeid: "event:weekly-inactive", status: :inactive, event_config: { weekly_research_enabled: true })

    assert_no_enqueued_jobs(only: EventResearchTaskJob) { WeeklyEventResearchJob.perform_now }
    assert_empty EventResearchTask.all
  end
end
