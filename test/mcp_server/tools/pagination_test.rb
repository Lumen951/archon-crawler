require "test_helper"

# Regression for per_page across the paginated MCP tools.
#
# Each computed `per_page = [[per_page.to_i, 25].max, 100].min`, which turned
# the documented "默认 25" into a hard minimum: any explicit per_page below 25
# was silently raised to 25 (per_page: 10 returned 25 rows). The tools now
# clamp to 1..100, with values below 1 falling back to the default of 25 —
# the same rule the REST API uses via Api::BaseController#pagination_params.
module Tools
  class PaginationTest < ActiveSupport::TestCase
    # Tool name => the key holding its rows in the response.
    PAGINATED_TOOLS = {
      "list_articles" => "articles",
      "search_articles" => "articles",
      "list_event_research_runs" => "runs"
    }.freeze

    setup do
      @account = WechatAccount.create!(fakeid: "mcp_pagination", nickname: "分页测试号", status: :active)

      30.times do |i|
        @account.articles.create!(
          title: "分页 #{i} 共同学",
          url: "https://example.com/mcp-page-#{i}-#{SecureRandom.hex(8)}",
          published_at: i.days.ago
        )
      end

      event_account = EventAccount.create!(nickname: "分页大会", fakeid: "event:mcp-pagination")
      30.times do
        EventResearchRun.create!(account: event_account, status: :failed)
      end
    end

    def call_tool(tool, per_page: 25, page: 1)
      case tool
      when "list_articles"
        ListArticlesTool.call(server_context: {}, account_id: @account.id, per_page: per_page, page: page)
      when "search_articles"
        SearchArticlesTool.call(server_context: {}, keyword: "共同学", per_page: per_page, page: page)
      when "list_event_research_runs"
        ListEventResearchRunsTool.call(server_context: {}, per_page: per_page, page: page)
      end
    end

    def parsed(response)
      assert_not response.error?, "expected a successful tool response"
      JSON.parse(response.content.first[:text])
    end

    # These three paginate a result set the test fully controls, so the number
    # of returned rows can be asserted alongside the echoed per_page.
    PAGINATED_TOOLS.each do |tool, rows_key|
      test "#{tool} honours per_page below 25" do
        [ 1, 5, 10, 24 ].each do |requested|
          data = parsed(call_tool(tool, per_page: requested))

          assert_equal requested, data["per_page"], "#{tool} per_page=#{requested}"
          assert_equal requested, data[rows_key].length, "#{tool} per_page=#{requested} row count"
        end
      end

      test "#{tool} defaults per_page to 25" do
        data = parsed(call_tool(tool))

        assert_equal 25, data["per_page"]
        assert_equal 25, data[rows_key].length
      end

      test "#{tool} caps per_page at 100" do
        assert_equal 100, parsed(call_tool(tool, per_page: 500))["per_page"]
      end

      test "#{tool} falls back to the default for non-positive per_page" do
        [ 0, -5, nil ].each do |bad|
          assert_equal 25, parsed(call_tool(tool, per_page: bad))["per_page"], "#{tool} per_page=#{bad.inspect}"
        end
      end

      test "#{tool} falls back to page 1 for a non-positive page" do
        [ 0, -3 ].each do |bad|
          data = parsed(call_tool(tool, per_page: 10, page: bad))

          assert_equal 1, data["page"], "#{tool} page=#{bad}"
        end
      end

      test "#{tool} paginates past the first page" do
        data = parsed(call_tool(tool, per_page: 10, page: 3))

        assert_equal 3, data["page"]
        assert_equal 10, data[rows_key].length
        assert_equal 30, data["total_count"]
      end
    end

    # list_accounts paginates the global account table, so only the echoed
    # per_page is asserted — fixtures decide how many rows exist.
    test "list_accounts honours per_page below 25" do
      [ 1, 5, 10, 24 ].each do |requested|
        data = parsed(ListAccountsTool.call(server_context: {}, per_page: requested))

        assert_equal requested, data["per_page"]
        assert_operator data["accounts"].length, :<=, requested
      end
    end

    test "list_accounts caps per_page at 100 and defaults non-positive values" do
      assert_equal 100, parsed(ListAccountsTool.call(server_context: {}, per_page: 500))["per_page"]

      [ 0, -5, nil ].each do |bad|
        assert_equal 25, parsed(ListAccountsTool.call(server_context: {}, per_page: bad))["per_page"]
      end
    end

    test "string per_page values are accepted" do
      data = parsed(ListArticlesTool.call(server_context: {}, account_id: @account.id, per_page: "10"))

      assert_equal 10, data["per_page"]
    end
  end
end
