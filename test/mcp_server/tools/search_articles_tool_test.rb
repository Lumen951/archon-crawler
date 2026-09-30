require "test_helper"

module Tools
  class SearchArticlesToolTest < ActiveSupport::TestCase
    setup do
      @account = accounts(:one)
      @matched = @account.articles.create!(
        title: "分布式爬虫系统设计",
        url: "https://example.com/mcp-search-1-#{SecureRandom.hex(8)}",
        digest: "爬虫调度与去重",
        content_markdown: "本文讨论分布式爬虫",
        published_at: Time.current
      )
      @other_account = WechatAccount.create!(
        fakeid: "mcp_search_fakeid_#{SecureRandom.hex(4)}",
        nickname: "另一个账号",
        status: :active
      )
      @unmatched = @other_account.articles.create!(
        title: "无关的文章",
        url: "https://example.com/mcp-search-2-#{SecureRandom.hex(8)}",
        published_at: 1.day.ago
      )
    end

    test "returns matching articles with account info" do
      response = Tools::SearchArticlesTool.call(server_context: {}, keyword: "爬虫")
      assert_not response.error?

      data = JSON.parse(response.content.first[:text])
      ids = data["articles"].map { |a| a["id"] }

      assert_includes ids, @matched.id
      assert_not_includes ids, @unmatched.id

      entry = data["articles"].find { |a| a["id"] == @matched.id }
      assert_equal "Test Account", entry["account"]["nickname"]
      assert_equal "wechat", entry["account"]["platform"]
      assert_equal @matched.url, entry["url"]
      assert_equal "爬虫", data["keyword"]
    end

    test "filters by platform" do
      response = Tools::SearchArticlesTool.call(server_context: {}, keyword: "爬虫", platform: "twitter")
      assert_not response.error?
      assert_empty JSON.parse(response.content.first[:text])["articles"]
    end

    test "rejects unknown platform" do
      response = Tools::SearchArticlesTool.call(server_context: {}, keyword: "爬虫", platform: "facebook")
      assert response.error?
      assert_includes response.content.first[:text], "不支持的平台"
    end

    test "rejects blank keyword" do
      response = Tools::SearchArticlesTool.call(server_context: {}, keyword: "")
      assert response.error?
    end

    test "rejects invalid date" do
      response = Tools::SearchArticlesTool.call(server_context: {}, keyword: "爬虫", start_date: "not-a-date")
      assert response.error?
      assert_includes response.content.first[:text], "start_date 格式无效"
    end

    test "is registered as a read-only MCP tool" do
      assert_includes McpController::TOOLS, Tools::SearchArticlesTool
      assert_not McpOauth.write_tool?("search_articles")
    end
  end
end
