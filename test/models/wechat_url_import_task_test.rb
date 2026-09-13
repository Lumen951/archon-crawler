require "test_helper"

# == Schema Information
#
# Table name: wechat_url_import_tasks
#
#  id              :bigint           not null, primary key
#  completed_at    :datetime
#  created_count   :integer          default(0), not null
#  error_message   :text
#  failed_count    :integer          default(0), not null
#  found_count     :integer          default(0), not null
#  processed_count :integer          default(0), not null
#  started_at      :datetime
#  status          :integer          default(0), not null
#  total_count     :integer          default(0), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_wechat_url_import_tasks_on_status  (status)
#
class WechatUrlImportTaskTest < ActiveSupport::TestCase
  test "calculates progress percentage" do
    task = WechatUrlImportTask.create!(total_count: 4)

    assert_equal 0, task.progress_percentage
    task.update!(processed_count: 1)
    assert_equal 25.0, task.progress_percentage
  end

  test "records created, found, and failed outcomes atomically" do
    task = WechatUrlImportTask.create!(total_count: 3)
    created = task.items.create!(url: "https://mp.weixin.qq.com/s/created")
    found = task.items.create!(url: "https://mp.weixin.qq.com/s/found")
    failed = task.items.create!(url: "https://mp.weixin.qq.com/s/failed")
    account = WechatAccount.create!(fakeid: "task_test", nickname: "测试帐号", status: :active)

    task.record_created!(created, account)
    task.record_found!(found, account)
    task.record_failed!(failed, "解析失败")
    task.reload

    assert_equal 3, task.processed_count
    assert_equal 1, task.created_count
    assert_equal 1, task.found_count
    assert_equal 1, task.failed_count
    assert task.completed? == false
    assert_equal "failed", failed.reload.status
  end

  test "only a pending task can start running" do
    task = WechatUrlImportTask.create!(status: :completed)

    assert_equal false, task.mark_running!
    assert task.completed?
  end
end
