require "test_helper"

class WeeklyEventResearchJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "只为启用持续研究的账号启动并强制忽略缓存" do
    enabled = EventAccount.create!(nickname: "启用活动", fakeid: "event:weekly-enabled", event_config: { weekly_research_enabled: true })
    EventAccount.create!(nickname: "停用活动", fakeid: "event:weekly-disabled", event_config: { weekly_research_enabled: false })

    assert_enqueued_with(job: EventResearchJob) do
      WeeklyEventResearchJob.perform_now
    end

    run = enabled.event_research_runs.sole
    assert run.refresh_cache?
  end

  test "停用的账号即使开着周调研也不启动" do
    inactive = EventAccount.create!(
      nickname: "停用但开了周调研",
      fakeid: "event:weekly-inactive",
      status: :inactive,
      event_config: { weekly_research_enabled: true }
    )

    assert_no_enqueued_jobs only: EventResearchJob do
      WeeklyEventResearchJob.perform_now
    end

    assert_empty inactive.event_research_runs.reload
  end
end
