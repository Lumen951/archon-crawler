require "test_helper"

class ArticleTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:one)
    @in_title = @account.articles.create!(
      title: "微信公众号爬虫实战",
      url: "https://example.com/search-title-#{SecureRandom.hex(8)}",
      published_at: 1.day.ago
    )
    @in_digest = @account.articles.create!(
      title: "无关标题甲",
      url: "https://example.com/search-digest-#{SecureRandom.hex(8)}",
      digest: "本文介绍爬虫框架",
      published_at: 2.days.ago
    )
    @in_markdown = @account.articles.create!(
      title: "无关标题乙",
      url: "https://example.com/search-markdown-#{SecureRandom.hex(8)}",
      content_markdown: "正文里提到爬虫工具",
      published_at: 3.days.ago
    )
    @in_html_only = @account.articles.create!(
      title: "无关标题丙",
      url: "https://example.com/search-html-#{SecureRandom.hex(8)}",
      content_html: "<p>正文里提到爬虫框架</p>",
      published_at: 4.days.ago
    )
    @no_match = @account.articles.create!(
      title: "完全无关的文章",
      url: "https://example.com/search-none-#{SecureRandom.hex(8)}",
      published_at: 5.days.ago
    )
  end

  test "search_keyword matches title, digest, markdown and html-only body" do
    results = Article.search_keyword("爬虫")

    assert_includes results, @in_title
    assert_includes results, @in_digest
    assert_includes results, @in_markdown
    assert_includes results, @in_html_only
    assert_not_includes results, @no_match
  end

  test "search_keyword ANDs space-separated terms" do
    results = Article.search_keyword("爬虫 实战")

    assert_includes results, @in_title
    assert_not_includes results, @in_markdown

    assert_empty Article.search_keyword("爬虫 不存在的词")
  end

  test "search_keyword treats SQL wildcards as literals" do
    percent = @account.articles.create!(
      title: "100% 全力冲刺",
      url: "https://example.com/search-wildcard-#{SecureRandom.hex(8)}",
      published_at: 6.days.ago
    )

    assert_includes Article.search_keyword("%"), percent
    assert_empty Article.search_keyword("%%")
    assert_empty Article.search_keyword("100_")
  end

  test "search_keyword is case-insensitive" do
    results = Article.search_keyword("TEST ARTICLE")

    assert_includes results, articles(:one)
    assert_not_includes results, @in_title
  end

  test "search_keyword returns all articles for blank keyword" do
    assert_equal Article.count, Article.search_keyword("").count
    assert_equal Article.count, Article.search_keyword(nil).count
    assert_equal Article.count, Article.search_keyword("   ").count
  end
end
