require "test_helper"

class EventResearchTaskTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @first = EventAccount.create!(nickname: "活动一", fakeid: "event:task-one")
    @second = EventAccount.create!(nickname: "活动二", fakeid: "event:task-two")
  end

  test "创建任务会固定活动成员快照" do
    task = EventResearchTask.create_for!(EventAccount.where(id: [ @first.id, @second.id ]), source: :manual_selected)

    assert_equal 2, task.total
    assert_equal [ @first.id, @second.id ].sort, task.event_research_task_accounts.pluck(:account_id).sort
    assert task.pending?
  end

  test "完成、失败和跳过成员全部结算后汇总任务状态" do
    task = EventResearchTask.create_for!([ @first, @second ], source: :manual_selected)
    task.mark_running!
    completed, skipped = task.event_research_task_accounts.order(:id).to_a
    completed.mark_completed!
    skipped.mark_skipped!("已有进行中的调研")
    task.update!(progress: 2)

    task.finalize!

    assert task.reload.completed?
    assert_equal 1, task.completed_account_count
    assert_equal 1, task.skipped_account_count
  end

  test "失败成员使任务失败但不会丢失成功成员" do
    task = EventResearchTask.create_for!([ @first, @second ], source: :manual_selected)
    task.mark_running!
    successful, failed = task.event_research_task_accounts.order(:id).to_a
    successful.mark_completed!
    failed.mark_failed!("请求超时")
    task.update!(progress: 2)

    task.finalize!

    assert task.reload.failed?
    assert_equal 1, task.completed_account_count
    assert_equal 1, task.failed_account_count
  end

  test "已完成任务不能恢复或重新入队" do
    task = EventResearchTask.create_for!([ @first ], source: :manual_single)
    task.update!(status: :completed, progress: 1, completed_at: Time.current)

    assert_no_enqueued_jobs(only: EventResearchTaskJob) { assert_not task.resume! }
    assert task.reload.completed?
  end

  test "任务 API 用量只汇总成员当前关联的运行结果" do
    task = EventResearchTask.create_for!([ @first, @second ], source: :manual_selected)
    first_run = EventResearchRun.create!(account: @first, status: :completed, result: usage_result(search_calls: 3, search_hits: 2, tianyancha_calls: 1, tianyancha_hits: 4))
    replaced_run = EventResearchRun.create!(account: @second, status: :failed, result: usage_result(search_calls: 1, search_hits: 5, tianyancha_calls: 2, tianyancha_hits: 3))
    EventResearchRun.create!(account: @first, status: :completed, result: usage_result(search_calls: 99, search_hits: 99, tianyancha_calls: 99, tianyancha_hits: 99))

    first_item, second_item = task.event_research_task_accounts.order(:id).to_a
    first_item.update!(event_research_run: first_run, status: :completed)
    second_item.update!(event_research_run: replaced_run, status: :failed)

    assert_equal({
      "search" => { "api_calls" => 4, "cache_hits" => 7 },
      "tianyancha" => { "api_calls" => 3, "cache_hits" => 7 }
    }, task.api_usage(task.event_research_task_accounts.includes(:event_research_run)))
  end

  test "任务 API 用量兼容跳过成员和缺失或旧格式结果" do
    task = EventResearchTask.create_for!([ @first, @second ], source: :manual_selected)
    run = EventResearchRun.create!(account: @first, status: :failed, result: { "metadata" => { "cache" => { "search" => { "hit" => "2" } } } })
    item, skipped = task.event_research_task_accounts.order(:id).to_a
    item.update!(event_research_run: run, status: :failed)
    skipped.mark_skipped!("已有进行中的调研")

    assert_equal({
      "search" => { "api_calls" => 0, "cache_hits" => 2 },
      "tianyancha" => { "api_calls" => 0, "cache_hits" => 0 }
    }, task.api_usage(task.event_research_task_accounts.includes(:event_research_run)))
  end

  test "恢复只重置失败和遗留运行成员" do
    task = EventResearchTask.create_for!([ @first, @second ], source: :manual_selected)
    completed, failed = task.event_research_task_accounts.order(:id).to_a
    completed.mark_completed!
    failed.mark_failed!("请求超时")
    task.update!(status: :failed, progress: 2, completed_at: Time.current)

    assert_enqueued_with(job: EventResearchTaskJob, args: [ task.id ]) { task.resume! }

    assert task.reload.pending?
    assert completed.reload.completed?
    assert failed.reload.pending?
  end

  private

  def usage_result(search_calls:, search_hits:, tianyancha_calls:, tianyancha_hits:)
    {
      "metadata" => {
        "cache" => {
          "search" => { "miss" => search_calls, "hit" => search_hits },
          "tianyancha" => { "hit" => tianyancha_hits }
        },
        "companies" => { "api_calls" => tianyancha_calls }
      }
    }
  end
end
