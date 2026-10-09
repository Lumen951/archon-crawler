require "test_helper"

module Tools
  class ListArticlesToolTest < ActiveSupport::TestCase
    setup do
      @account = accounts(:one)
      @matched = @account.articles.create!(
        title: "爬虫调度策略",
        url: "https://example.com/mcp-list-1-#{SecureRandom.hex(8)}",
        published_at: Time.current
      )
      @unmatched = @account.articles.create!(
        title: "别的主题",
        url: "https://example.com/mcp-list-2-#{SecureRandom.hex(8)}",
        published_at: 1.day.ago
      )
    end

    test "keyword narrows the article list" do
      response = Tools::ListArticlesTool.call(server_context: {}, account_id: @account.id, keyword: "爬虫调度")
      assert_not response.error?

      data = JSON.parse(response.content.first[:text])
      ids = data["articles"].map { |a| a["id"] }

      assert_includes ids, @matched.id
      assert_not_includes ids, @unmatched.id
    end

    # A term below the trigram minimum cannot use the GIN indexes, so the tool
    # caps its scan (Article.with_search_timeout) rather than refusing it. A scan
    # that runs past the cap comes back as a tool error with the reason.
    test "reports a short keyword whose scan was cut off" do
      stub_class_method(Article, :with_search_timeout, ->(*) { nil }) do
        response = Tools::ListArticlesTool.call(server_context: {}, account_id: @account.id, keyword: "甄劢")

        assert response.error?
        assert_includes response.content.first[:text], "甄劢"
        assert_includes response.content.first[:text], "超时"
      end
    end

    test "searches a short keyword when the scan finishes in time" do
      short_match = @account.articles.create!(
        title: "教育行业观察",
        url: "https://example.com/mcp-list-short-#{SecureRandom.hex(8)}",
        published_at: 2.days.ago
      )

      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql].to_s if payload[:sql].to_s.match?(/ILIKE/i)
      end
      response = Tools::ListArticlesTool.call(server_context: {}, account_id: @account.id, keyword: "教育")
      ActiveSupport::Notifications.unsubscribe(subscriber)

      assert_not response.error?
      assert_not_empty queries, "expected the short keyword to be searched, not refused"
      assert_includes JSON.parse(response.content.first[:text])["articles"].map { |a| a["id"] }, short_match.id
    end

    test "accepts a keyword of exactly 3 characters" do
      response = Tools::ListArticlesTool.call(server_context: {}, account_id: @account.id, keyword: "爬虫调")
      assert_not response.error?
    end

    test "caps a keyword with one short term among long ones" do
      stub_class_method(Article, :with_search_timeout, ->(*) { nil }) do
        response = Tools::ListArticlesTool.call(server_context: {}, account_id: @account.id, keyword: "人工智能 甄劢")

        assert response.error?
        assert_includes response.content.first[:text], "甄劢"
      end
    end

    test "blank keyword keeps full list" do
      response = Tools::ListArticlesTool.call(server_context: {}, account_id: @account.id, keyword: "")
      assert_not response.error?
      response = Tools::ListArticlesTool.call(server_context: {}, account_id: @account.id)
      assert_not response.error?

      ids = JSON.parse(response.content.first[:text])["articles"].map { |a| a["id"] }
      assert_includes ids, @matched.id
      assert_includes ids, @unmatched.id
    end

    test "unknown account returns an error" do
      response = Tools::ListArticlesTool.call(server_context: {}, account_id: -1)
      assert response.error?
    end
  end
end
