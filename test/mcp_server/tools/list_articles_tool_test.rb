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
      response = Tools::ListArticlesTool.call(server_context: {}, account_id: @account.id, keyword: "爬虫")
      assert_not response.error?

      data = JSON.parse(response.content.first[:text])
      ids = data["articles"].map { |a| a["id"] }

      assert_includes ids, @matched.id
      assert_not_includes ids, @unmatched.id
    end

    test "blank keyword keeps full list" do
      response = Tools::ListArticlesTool.call(server_context: {}, account_id: @account.id, keyword: "")
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
