require "test_helper"

# 活动调研的 MCP 只读工具：列表 + 结果获取
class EventResearchToolsTest < ActiveSupport::TestCase
  setup do
    @account = EventAccount.create!(nickname: "测试大会", fakeid: "event:mcp")
    @completed = EventResearchRun.create!(account: @account, status: :running)
    @completed.store_result!(research_result)
  end

  test "list_event_research_runs 返回运行记录列表" do
    response = Tools::ListEventResearchRunsTool.call(server_context: {})

    assert_not response.error?
    body = JSON.parse(response.content.first[:text])
    assert_equal 1, body["total_count"]
    run = body["runs"].first
    assert_equal @completed.id, run["id"]
    assert_equal "completed", run["status"]
    assert_equal "测试大会", run.dig("account", "nickname")
  end

  test "list_event_research_runs 按状态过滤" do
    EventResearchRun.create!(account: @account, status: :failed, error_message: "超时")

    response = Tools::ListEventResearchRunsTool.call(server_context: {}, status: "failed")

    body = JSON.parse(response.content.first[:text])
    assert_equal 1, body["total_count"]
    assert_equal "failed", body["runs"].first["status"]
  end

  test "list_event_research_runs 拒绝无效状态" do
    response = Tools::ListEventResearchRunsTool.call(server_context: {}, status: "bogus")

    assert response.error?
  end

  test "list_event_research_runs 对不存在的账号返回错误" do
    response = Tools::ListEventResearchRunsTool.call(server_context: {}, account_id: 999_999)

    assert response.error?
  end

  test "get_event_research_result 按 run_id 返回完整结果" do
    response = Tools::GetEventResearchResultTool.call(server_context: {}, run_id: @completed.id)

    assert_not response.error?
    body = JSON.parse(response.content.first[:text])
    assert_equal "张三", body.dig("awards", 0, "people", 0, "name")
    assert body.key?("metadata")
  end

  test "get_event_research_result 按 account_id 取最近一次成功调研" do
    response = Tools::GetEventResearchResultTool.call(server_context: {}, account_id: @account.id)

    assert_not response.error?
    body = JSON.parse(response.content.first[:text])
    assert_equal "张三", body.dig("awards", 0, "people", 0, "name")
  end

  test "get_event_research_result 对没有结果的运行返回错误说明" do
    pending_run = EventResearchRun.create!(account: @account, status: :pending)

    response = Tools::GetEventResearchResultTool.call(server_context: {}, run_id: pending_run.id)

    assert response.error?
    assert_match(/pending/, response.content.first[:text])
  end

  test "get_event_research_result 对不存在的运行返回错误" do
    response = Tools::GetEventResearchResultTool.call(server_context: {}, run_id: 999_999)

    assert response.error?
  end

  test "get_event_research_result 缺少参数时返回错误" do
    response = Tools::GetEventResearchResultTool.call(server_context: {})

    assert response.error?
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
