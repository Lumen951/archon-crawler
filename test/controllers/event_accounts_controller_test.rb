require "test_helper"

class EventAccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Option.event_search_provider = "serper"
    @admin = User.create!(
      email_address: "event-admin@example.com", password: "password123",
      password_confirmation: "password123", role: :admin, email_confirmed_at: Time.current
    )
    @user = User.create!(
      email_address: "event-user@example.com", password: "password123",
      password_confirmation: "password123", role: :user, email_confirmed_at: Time.current
    )
  end

  teardown do
    Option.delete("serper_api_key")
    Option.delete("event_search_provider")
  end

  # --- 导入 / 编辑配置（AccountsController） --------------------------------

  test "管理员创建活动研究账号：配置归一化并跳转到研究控制台" do
    sign_in_as(@admin)

    post import_event_accounts_path, params: {
      event_account: {
        name: "测试大会", url: " https://a.com/official ",
        keywords: "路演\n决赛，路演", purpose: "找创始人"
      }
    }

    account = EventAccount.order(:id).last
    assert_redirected_to event_account_path(account)
    assert_equal "测试大会", account.nickname
    assert_equal "https://a.com/official", account.event_url
    assert_equal [ "路演", "决赛" ], account.keywords
    assert_equal "找创始人", account.purpose
    assert account.fakeid.start_with?("event:")
  end

  test "活动名称必填，缺省时返回 422 并回显表单" do
    sign_in_as(@admin)

    post import_event_accounts_path, params: { event_account: { name: "", purpose: "x" } }

    assert_response :unprocessable_entity
  end

  test "更新配置保留 metadata 里的其它键" do
    sign_in_as(@admin)
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:update", metadata: { "source" => "manual" })

    patch update_event_account_path(account), params: {
      event_account: { name: "测试大会 2026", keywords: "路演", purpose: "尽调" }
    }

    assert_redirected_to event_account_path(account)
    account.reload
    assert_equal "manual", account.metadata["source"], "event_config 之外的 metadata 键不该被动"
    assert_equal "测试大会 2026", account.nickname
    assert_equal [ "路演" ], account.keywords
  end

  test "非管理员无法打开活动导入页" do
    sign_in_as(@user)

    get import_event_page_accounts_path

    assert_redirected_to root_path
  end

  test "管理员打开活动导入页正常渲染（@account 需初始化，供表单取值）" do
    sign_in_as(@admin)

    get import_event_page_accounts_path

    assert_response :success
    assert_match "创建活动配置", response.body
    assert_match "固定搜索组合（13 条）", response.body
    assert_match CGI.escapeHTML('"活动名称" 获奖名单'), response.body
  end

  # --- 研究控制台 ------------------------------------------------------------

  test "管理员可以看到研究控制台的启动入口与运行记录" do
    account = EventAccount.create!(
      nickname: "测试大会", fakeid: "event:console", event_config: { keywords: [ "路演" ] }
    )
    sign_in_as(@admin)

    get event_account_path(account)

    assert_response :success
    assert_match "测试大会", response.body
    assert_match "活动配置", response.body
    assert_match "固定搜索组合（13 条）", response.body
    assert_match CGI.escapeHTML('"测试大会" 获奖名单'), response.body
    assert_match "测试大会 路演", response.body
    assert_match "开始调研", response.body
  end

  test "非管理员能看运行记录，但没有启动入口" do
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:console-user")
    sign_in_as(@user)

    get event_account_path(account)

    assert_response :success
    assert_match "活动配置", response.body
    assert_no_match(/开始调研/, response.body)
  end

  test "普通账号的 show 页重定向到研究控制台（活动研究有独立界面）" do
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:redirect")
    sign_in_as(@user)

    get account_path(account)

    assert_redirected_to event_account_path(account)
  end

  test "活动研究账号不支持抓取，点抓取会被引导回研究控制台" do
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:crawl")
    sign_in_as(@user)

    post crawl_account_path(account)

    assert_redirected_to event_account_path(account)
    assert_equal "活动研究账号不支持抓取，请在研究控制台启动调研", flash[:error]
    assert_empty CrawlTask.all, "活动研究账号不应创建抓取任务"
  end

  test "批量抓取排除活动研究账号，不会为它们创建抓取任务" do
    EventAccount.create!(nickname: "测试大会", fakeid: "event:bulk")
    sign_in_as(@admin)

    post bulk_crawl_accounts_path, params: { account_ids: [ EventAccount.order(:id).last.id ] }

    assert_redirected_to accounts_path
    assert_empty CrawlTask.all
  end

  # --- 启动调研 ---------------------------------------------------------------

  test "管理员启动调研：创建任务快照并入队任务执行" do
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:start")
    Option.serper_api_key = "test-key"
    sign_in_as(@admin)

    stub_class_method(LlmClient, :configured?, -> { true }) do
      assert_enqueued_with(job: EventResearchTaskJob) do
        post start_research_event_account_path(account), params: { refresh_cache: "1" }
      end
    end

    task = EventResearchTask.order(:id).last
    assert_redirected_to event_research_task_path(task)
    assert task.manual_single?
    assert task.refresh_cache?
    assert_equal [ account.id ], task.event_research_task_accounts.pluck(:account_id)
  end

  test "未配置 Serper 密钥时启动直接被挡下，不创建运行记录" do
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:nokey")
    sign_in_as(@admin)

    stub_class_method(LlmClient, :configured?, -> { true }) do
      post start_research_event_account_path(account)
    end

    assert_redirected_to event_account_path(account)
    assert_match(/Serper/, flash[:error])
    assert_empty EventResearchRun.where(account: account)
  end

  test "非管理员无法启动调研" do
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:deny")
    Option.serper_api_key = "test-key"
    sign_in_as(@user)

    post start_research_event_account_path(account)

    assert_redirected_to root_path
    assert_empty EventResearchRun.where(account: account)
  end

  test "已有进行中的调研时仍创建任务，运行时会跳过该活动" do
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:dup")
    EventResearchRun.create!(account: account, status: :running)
    Option.serper_api_key = "test-key"
    sign_in_as(@admin)

    stub_class_method(LlmClient, :configured?, -> { true }) do
      post start_research_event_account_path(account)
    end

    task = EventResearchTask.order(:id).last
    assert_redirected_to event_research_task_path(task)
    assert_equal [ account.id ], task.event_research_task_accounts.pluck(:account_id)
    assert_equal 1, EventResearchRun.where(account: account).count
  end

  test "卡死的运行可以手动标记为失败，之后能重新启动" do
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:stuck")
    run = EventResearchRun.create!(account: account, status: :running)
    Option.serper_api_key = "test-key"
    sign_in_as(@admin)

    post fail_run_event_account_path(account, run_id: run.id)

    assert_redirected_to event_account_path(account, run_id: run.id)
    assert_equal "failed", run.reload.status

    stub_class_method(LlmClient, :configured?, -> { true }) do
      assert_enqueued_with(job: EventResearchTaskJob) do
        post start_research_event_account_path(account)
      end
    end
    assert_equal 1, EventResearchRun.where(account: account).count
    assert_equal 1, EventResearchTask.where(source: :manual_single).count
  end

  test "日志页按级别过滤并分页" do
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:logs")
    run = EventResearchRun.create!(account: account, status: :running)
    CrawlLog.log(run, :info, "Search: 测试大会", force: true)
    CrawlLog.log(run, :error, "抓取失败", force: true)
    sign_in_as(@user)

    get logs_event_account_path(account, run_id: run.id, level: "error")

    assert_response :success
    assert_match "抓取失败", response.body
    assert_no_match(/Search: 测试大会/, response.body)
  end

  test "poll 返回 Turbo Stream 更新研究主体" do
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:poll")
    run = EventResearchRun.create!(account: account, status: :running)
    sign_in_as(@user)

    get poll_event_account_path(account, run_id: run.id), headers: { Accept: "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "turbo-stream", response.body
    assert_match "research_body", response.body
  end

  test "下载按钮返回调研结果 JSON 文件" do
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:download")
    run = EventResearchRun.create!(account: account, status: :completed)
    run.store_result!({ "event" => { "name" => "测试大会" }, "awards" => [ { "rank" => "一等奖" } ], "metadata" => { "people_found" => 1 } })
    sign_in_as(@user)

    get download_event_account_path(account, run_id: run.id)

    assert_response :success
    assert_equal "application/json", response.media_type
    body = JSON.parse(response.body)
    assert_equal "测试大会", body.dig("event", "name")
  end

  private

  def sign_in_as(user)
    post session_path, params: { email_address: user.email_address, password: "password123" }
  end
end
