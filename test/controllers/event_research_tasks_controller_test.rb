require "test_helper"

class EventResearchTasksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(email_address: "tasks-admin@example.com", password: "password123", password_confirmation: "password123", role: :admin, email_confirmed_at: Time.current)
    @user = User.create!(email_address: "tasks-user@example.com", password: "password123", password_confirmation: "password123", role: :user, email_confirmed_at: Time.current)
    @first = EventAccount.create!(nickname: "活动一", fakeid: "event:tasks-one")
    @second = EventAccount.create!(nickname: "活动二", fakeid: "event:tasks-two")
  end

  test "管理员可为显式选择的活动创建研究任务" do
    sign_in_as(@admin)

    assert_enqueued_with(job: EventResearchTaskJob) do
      post event_research_tasks_path, params: { account_ids: [ @first.id, @second.id ] }
    end

    task = EventResearchTask.order(:id).last
    assert_redirected_to event_research_task_path(task)
    assert task.manual_selected?
    assert_equal [ @first.id, @second.id ].sort, task.event_research_task_accounts.pluck(:account_id).sort
  end

  test "全选只创建当前筛选范围内已启用的活动任务" do
    matching = EventAccount.create!(nickname: "匹配活动", fakeid: "event:tasks-match")
    EventAccount.create!(nickname: "其他活动", fakeid: "event:tasks-other")
    EventAccount.create!(nickname: "已停用匹配", fakeid: "event:tasks-inactive", status: :inactive)
    sign_in_as(@admin)

    post event_research_tasks_path, params: { select_all: "true", q: { nickname_cont: "匹配" } }

    task = EventResearchTask.order(:id).last
    assert task.manual_all?
    assert_equal [ matching.id ], task.event_research_task_accounts.pluck(:account_id)
  end

  test "非管理员不能创建研究任务" do
    sign_in_as(@user)

    post event_research_tasks_path, params: { account_ids: [ @first.id ] }

    assert_redirected_to root_path
    assert_empty EventResearchTask.all
  end

  test "空选择返回活动列表并显示错误" do
    sign_in_as(@admin)

    post event_research_tasks_path

    assert_redirected_to accounts_path(scope: "event")
    assert_match "请选择至少一个已启用的活动", flash[:error]
  end

  test "任务日志页支持按级别筛选" do
    task = EventResearchTask.create_for!([ @first ], source: :manual_single)
    CrawlLog.log(task, :info, "开始研究", force: true)
    CrawlLog.log(task, :error, "请求失败", force: true)
    sign_in_as(@user)

    get logs_event_research_task_path(task, level: "error")

    assert_response :success
    assert_match "活动研究任务日志", response.body
    assert_match "请求失败", response.body
    assert_no_match "开始研究", response.body
  end

  test "poll 返回任务主体 Turbo Stream" do
    task = EventResearchTask.create_for!([ @first ], source: :manual_single)
    sign_in_as(@user)

    get poll_event_research_task_path(task), headers: { Accept: "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "turbo-stream", response.body
    assert_match dom_id(task, :show_body), response.body
  end

  test "任务详情和轮询展示 API 调用及缓存命中统计" do
    task = EventResearchTask.create_for!([ @first ], source: :manual_single)
    run = EventResearchRun.create!(account: @first, status: :completed, result: {
      "metadata" => {
        "cache" => {
          "search" => { "miss" => 3, "hit" => 4 },
          "tianyancha" => { "hit" => 6 }
        },
        "companies" => { "api_calls" => 2 }
      }
    })
    task.event_research_task_accounts.sole.update!(event_research_run: run, status: :completed)
    sign_in_as(@user)

    get event_research_task_path(task)

    assert_response :success
    assert_match "搜索 API 调用", response.body
    assert_match "天眼查缓存命中", response.body
    assert_match ">3<", response.body
    assert_match ">6<", response.body

    get poll_event_research_task_path(task), headers: { Accept: "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "搜索缓存命中", response.body
    assert_match ">2<", response.body
  end

  private

  def sign_in_as(user)
    post session_path, params: { email_address: user.email_address, password: "password123" }
  end
end
