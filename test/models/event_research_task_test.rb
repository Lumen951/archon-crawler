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
end
