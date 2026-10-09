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
      response = Tools::SearchArticlesTool.call(server_context: {}, keyword: "爬虫调度")
      assert_not response.error?

      data = JSON.parse(response.content.first[:text])
      ids = data["articles"].map { |a| a["id"] }

      assert_includes ids, @matched.id
      assert_not_includes ids, @unmatched.id

      entry = data["articles"].find { |a| a["id"] == @matched.id }
      assert_equal "Test Account", entry["account"]["nickname"]
      assert_equal "wechat", entry["account"]["platform"]
      assert_equal @matched.url, entry["url"]
      assert_equal "爬虫调度", data["keyword"]
    end

    # A term below the trigram minimum cannot use the GIN indexes, so the tool
    # caps its scan (Article.with_search_timeout) rather than refusing it. A scan
    # that runs past the cap comes back as a tool error with the reason.
    test "reports a short keyword whose scan was cut off" do
      stub_class_method(Article, :with_search_timeout, ->(*) { nil }) do
        response = Tools::SearchArticlesTool.call(server_context: {}, keyword: "甄劢")

        assert response.error?
        assert_includes response.content.first[:text], "甄劢"
        assert_includes response.content.first[:text], "超时"
      end
    end

    test "searches a short keyword when the scan finishes in time" do
      short_match = @account.articles.create!(
        title: "教育行业观察",
        url: "https://example.com/mcp-search-short-#{SecureRandom.hex(8)}",
        published_at: 2.days.ago
      )

      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql].to_s if payload[:sql].to_s.match?(/ILIKE/i)
      end
      response = Tools::SearchArticlesTool.call(server_context: {}, keyword: "教育")
      ActiveSupport::Notifications.unsubscribe(subscriber)

      assert_not response.error?
      assert_not_empty queries, "expected the short keyword to be searched, not refused"
      assert_includes JSON.parse(response.content.first[:text])["articles"].map { |a| a["id"] }, short_match.id
    end

    test "accepts a keyword of exactly 3 characters" do
      response = Tools::SearchArticlesTool.call(server_context: {}, keyword: "爬虫调")
      assert_not response.error?
    end

    test "caps a keyword with one short term among long ones" do
      stub_class_method(Article, :with_search_timeout, ->(*) { nil }) do
        response = Tools::SearchArticlesTool.call(server_context: {}, keyword: "人工智能 甄劢")

        assert response.error?
        assert_includes response.content.first[:text], "甄劢"
      end
    end

    test "filters by platform" do
      response = Tools::SearchArticlesTool.call(server_context: {}, keyword: "爬虫调度", platform: "twitter")
      assert_not response.error?
      assert_empty JSON.parse(response.content.first[:text])["articles"]
    end

    test "rejects unknown platform" do
      response = Tools::SearchArticlesTool.call(server_context: {}, keyword: "爬虫调度", platform: "facebook")
      assert response.error?
      assert_includes response.content.first[:text], "不支持的平台"
    end

    test "rejects blank keyword" do
      response = Tools::SearchArticlesTool.call(server_context: {}, keyword: "")
      assert response.error?
    end

    test "rejects invalid date" do
      response = Tools::SearchArticlesTool.call(server_context: {}, keyword: "爬虫调度", start_date: "not-a-date")
      assert response.error?
      assert_includes response.content.first[:text], "start_date 格式无效"
    end

    test "is registered as a read-only MCP tool" do
      assert_includes McpController::TOOLS, Tools::SearchArticlesTool
      assert_not McpOauth.write_tool?("search_articles")
    end
  end
end
