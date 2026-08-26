require "test_helper"

class WechatUrlImportTasksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email_address: "tasks@example.com",
      password: "password123",
      password_confirmation: "password123",
      role: :admin,
      email_confirmed_at: Time.current
    )
    post session_path, params: { email_address: @user.email_address, password: "password123" }
  end

  test "shows task progress" do
    task = WechatUrlImportTask.create!(total_count: 1, status: :running)
    task.items.create!(url: "https://mp.weixin.qq.com/s/test")

    get wechat_url_import_task_path(task)

    assert_response :success
    assert_match "微信文章链接导入任务", response.body
    assert_match "1 个链接已处理", response.body
  end

  test "does not delete an active task" do
    task = WechatUrlImportTask.create!(total_count: 1, status: :running)

    delete wechat_url_import_task_path(task)

    assert_redirected_to wechat_url_import_task_path(task)
    assert WechatUrlImportTask.exists?(task.id)
  end

  test "deletes a terminal task" do
    task = WechatUrlImportTask.create!(total_count: 1, status: :completed)

    delete wechat_url_import_task_path(task)

    assert_redirected_to wechat_url_import_tasks_path
    assert_not WechatUrlImportTask.exists?(task.id)
  end
end
