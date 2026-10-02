require "test_helper"

# 活动调研数据 API（只读）：/api/v1/event_research_runs
class EventResearchApiTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email_address: "event-api@example.com", password: "password123",
      password_confirmation: "password123", role: :user, email_confirmed_at: Time.current
    )
    @api_key = @user.api_keys.create!(name: "test")
    @headers = { Authorization: "Bearer #{@api_key.token}", Accept: "application/json" }

    @account = EventAccount.create!(nickname: "测试大会", fakeid: "event:api")
    @completed = EventResearchRun.create!(account: @account, status: :running)
    @completed.store_result!(research_result)
    @failed = EventResearchRun.create!(account: @account, status: :failed, error_message: "超时")
  end

  test "缺少 API key 时返回 401" do
    get "/api/v1/event_research_runs"

    assert_response :unauthorized
  end

  test "index 运行记录列表带分页" do
    get "/api/v1/event_research_runs", headers: @headers

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body["event_research_runs"].length
    assert_equal 2, body["pagination"]["total_count"]

    first = body["event_research_runs"].first
    assert_equal @failed.id, first["id"], "默认按创建时间倒序"
    assert_equal "测试大会", first.dig("account", "nickname")
    assert_not first.key?("result"), "列表不包含 result 全文"
  end

  test "index 支持按状态过滤，非法状态返回 400" do
    get "/api/v1/event_research_runs?status=completed", headers: @headers
    body = JSON.parse(response.body)
    assert_equal [ @completed.id ], body["event_research_runs"].map { |run| run["id"] }

    get "/api/v1/event_research_runs?status=bogus", headers: @headers
    assert_response :bad_request
  end

  test "latest=true 只返回每个账号最近一次成功调研" do
    older = EventResearchRun.create!(account: @account, status: :completed, created_at: 2.days.ago)
    older.store_result!(research_result)

    get "/api/v1/event_research_runs?latest=true", headers: @headers

    body = JSON.parse(response.body)
    ids = body["event_research_runs"].map { |run| run["id"] }
    assert_includes ids, @completed.id
    assert_not_includes ids, older.id, "每个账号只保留最近一次成功调研"
    assert_not_includes ids, @failed.id
  end

  test "show 返回完整 result JSON" do
    get "/api/v1/event_research_runs/#{@completed.id}", headers: @headers

    assert_response :success
    body = JSON.parse(response.body)
    run = body["event_research_run"]
    assert_equal @completed.id, run["id"]
    assert_equal "张三", run.dig("result", "awards", 0, "people", 0, "name")
    assert run["result"].key?("metadata")
  end

  test "show 对不存在的运行返回 404" do
    get "/api/v1/event_research_runs/999999", headers: @headers

    assert_response :not_found
  end

  private

  def research_result
    {
      "event" => { "name" => "测试大会", "year" => 2025, "edition" => nil },
      "awards" => [ { "rank" => "一等奖", "people" => [ { "name" => "张三" } ] } ],
      "companies" => [],
      "metadata" => { "people_found" => 1, "generated_at" => Time.current.iso8601 }
    }
  end
end
