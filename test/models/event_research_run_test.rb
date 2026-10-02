require "test_helper"

# == Schema Information
#
# Table name: event_research_runs
#
#  id            :bigint           not null, primary key
#  award_count   :integer
#  company_count :integer
#  completed_at  :datetime
#  error_message :text
#  people_count  :integer
#  refresh_cache :boolean          default(FALSE), not null
#  result        :jsonb
#  started_at    :datetime
#  status        :integer          default(0), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  account_id    :bigint           not null
#
# Indexes
#
#  index_event_research_runs_on_account_id                 (account_id)
#  index_event_research_runs_on_account_id_active          (account_id) UNIQUE WHERE (status = ANY (ARRAY[0, 1]))
#  index_event_research_runs_on_account_id_and_created_at  (account_id,created_at)
#  index_event_research_runs_on_status                     (status)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class EventResearchRunTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    @account = EventAccount.create!(nickname: "测试大会", fakeid: "event:run-test")
  end

  test "start_for! 创建 pending 运行并投递 EventResearchJob" do
    run = nil
    assert_enqueued_with(job: EventResearchJob) do
      run = EventResearchRun.start_for!(@account, refresh_cache: true)
    end

    assert_equal "pending", run.status
    assert run.refresh_cache?
  end

  test "同一账号已有进行中的调研时，start_for! 抛 ConcurrentRunError" do
    EventResearchRun.create!(account: @account, status: :running)

    error = assert_raises(EventResearchRun::ConcurrentRunError) do
      EventResearchRun.start_for!(@account)
    end

    assert_match(/已有进行中的调研/, error.message)
  end

  test "部分唯一索引兜底并发启动：直接插入第二条进行中记录会失败" do
    EventResearchRun.create!(account: @account, status: :running)

    assert_raises(ActiveRecord::RecordNotUnique) do
      EventResearchRun.create!(account: @account, status: :pending)
    end
  end

  test "完成 / 失败的运行不占用并发名额，可以再次启动" do
    EventResearchRun.create!(account: @account, status: :completed)
    EventResearchRun.create!(account: @account, status: :failed)

    assert_nothing_raised { EventResearchRun.start_for!(@account) }
  end

  test "mark_running! 只有 pending 能进入 running，重复投递返回 false" do
    run = EventResearchRun.create!(account: @account, status: :pending)

    assert run.mark_running!
    assert_equal "running", run.status
    assert run.started_at.present?

    assert_not run.mark_running!, "重复投递不应再次进入"
    assert run.reload.running?
  end

  test "store_result! 存结果、计数完成状态" do
    run = EventResearchRun.create!(account: @account, status: :running)
    result = {
      "event" => { "name" => "测试大会" },
      "awards" => [ { "rank" => "一等奖", "people" => [ { "name" => "张三" } ] } ],
      "companies" => [ { "name" => "甲公司", "found" => true } ],
      "metadata" => { "people_found" => 1 }
    }

    run.store_result!(result)

    assert_equal "completed", run.reload.status
    assert_equal result, run.result
    assert_equal 1, run.award_count
    assert_equal 1, run.people_count
    assert_equal 1, run.company_count
    assert_nil run.error_message
    assert run.completed_at.present?
  end

  test "退化结果如实保留数据，但状态标 failed" do
    run = EventResearchRun.create!(account: @account, status: :running)

    result = { "awards" => [], "metadata" => {} }
    run.store_result!(result)

    assert_equal "failed", run.reload.status
    assert_equal result, run.result
    assert_match(/没有提取到有效数据/, run.error_message)
  end

  test "mark_failed! 记录错误并结束运行" do
    run = EventResearchRun.create!(account: @account, status: :running)

    run.mark_failed!("网络超时")

    assert_equal "failed", run.reload.status
    assert_equal "网络超时", run.error_message
    assert run.completed_at.present?
  end

  test "latest_completed_for 取账号最近一次成功调研" do
    old = EventResearchRun.create!(account: @account, status: :completed, created_at: 2.days.ago)
    latest = EventResearchRun.create!(account: @account, status: :completed)
    EventResearchRun.create!(account: @account, status: :failed)

    assert_equal latest.id, EventResearchRun.latest_completed_for(@account).id
    assert_not_equal old.id, EventResearchRun.latest_completed_for(@account).id
  end

  test "删除运行时级联删除其日志" do
    run = EventResearchRun.create!(account: @account, status: :running)
    CrawlLog.log(run, :info, "过程日志", force: true)

    assert_difference -> { CrawlLog.count }, -1 do
      run.destroy
    end
  end
end
