require "test_helper"

class ArticlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email_address: "test@example.com",
      password: "password123",
      password_confirmation: "password123",
      role: :user,
      email_confirmed_at: Time.current
    )

    post session_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }

    @account = accounts(:one)
    @article = articles(:one)
  end

  test "should show article" do
    get article_path(@article)
    assert_response :success
    assert_select "h1", @article.title
  end

  test "should show article with html content" do
    @article.update!(content_html: "<p>Test content</p>")
    get article_path(@article)
    assert_response :success
    assert_select ".article-content p", "Test content"
  end

  test "should show article with markdown content fallback" do
    @article.update!(content_html: nil, content_markdown: "Test markdown")
    get article_path(@article)
    assert_response :success
  end

  test "should show article with digest when no content" do
    @article.update!(content_html: nil, content_markdown: nil, digest: "Test digest")
    get article_path(@article)
    assert_response :success
    assert_select "p", "Test digest"
  end

  test "should link to original article" do
    get article_path(@article)
    assert_response :success
    assert_select "a[href=?]", @article.url, text: "查看原文"
  end

  test "should not link back to account" do
    get article_path(@article)
    assert_response :success
    assert_select "a[href=?]", account_path(@article.account), count: 0
  end

  test "article show uses standalone layout" do
    get article_path(@article)
    assert_response :success
    assert_select "header", count: 0
    assert_select "[data-sidebar-target='panel']", count: 0
    assert_select "h1", @article.title
  end

  test "shows account identity on article index and show" do
    @account.update!(round_head_img: "https://example.com/avatar.png")

    get articles_path
    assert_response :success
    assert_select "a[href=?] img[src=?][alt=?]", account_path(@account), @account.round_head_img, @account.nickname
    assert_select "span", text: @account.platform_name

    @article.update!(cover_url: "https://example.com/cover.jpg")
    get articles_path
    assert_response :success
    assert_select "img[src=?]", @article.cover_url

    get article_path(@article)
    assert_response :success
    assert_select "img[src=?][alt=?]", @account.round_head_img, @account.nickname
    assert_select "span", text: @account.platform_name
    assert_select "span", text: @article.author
  end

  test "shows account fallback avatar when image is missing" do
    get articles_path
    assert_response :success
    assert_select "div.h-10.w-10", text: "💬"
  end

  test "should get articles index" do
    get articles_path
    assert_response :success
    assert_select "a[href=?]", article_path(@article)
  end

  test "articles index filters by keyword" do
    get articles_path, params: { keyword: @article.title }
    assert_response :success
    assert_select "a[href=?]", article_path(@article)

    get articles_path, params: { keyword: "不存在的关键词xyz" }
    assert_response :success
    assert_select "p", text: "没有匹配的文章"
  end

  test "articles index filters by platform" do
    get articles_path, params: { platform: "wechat" }
    assert_response :success
    assert_select "a[href=?]", article_path(@article)

    # accounts(:one) is a WechatAccount, so the website filter matches nothing
    get articles_path, params: { platform: "website" }
    assert_response :success
    assert_select "p", text: "没有匹配的文章"
  end

  test "account page filters articles by keyword" do
    get account_path(@account), params: { keyword: @article.title }
    assert_response :success
    assert_select "a[href=?]", article_path(@article)
  end

  # A term shorter than three characters yields no trigram, so it cannot use the
  # GIN indexes and its scan is capped rather than refused. A high-frequency
  # term reaches its LIMIT long before the cap and is searched normally; only a
  # scan that runs past it is interrupted, and the page says so.
  test "articles index runs a short keyword that finishes in time" do
    short_match = @account.articles.create!(
      title: "教育行业观察",
      url: "https://example.com/short-#{SecureRandom.hex(4)}",
      published_at: 1.day.ago
    )

    queries = search_queries { get articles_path, params: { keyword: "教育" } }

    assert_response :success
    assert_not_empty queries, "expected the short keyword to be searched, not refused"
    assert_select "a[href=?]", article_path(short_match)
    assert_select "p", text: /超时/, count: 0
  end

  test "articles index explains a short keyword whose scan was cut off" do
    stub_class_method(Article, :with_search_timeout, ->(*) { nil }) do
      get articles_path, params: { keyword: "甄劢" }
    end

    assert_response :success
    assert_select "p", text: /关键词「甄劢」/
    assert_select "p", text: /超时/
    assert_select "a[href=?]", article_path(@article), count: 0
  end

  test "account page runs a short keyword that finishes in time" do
    short_match = @account.articles.create!(
      title: "教育行业观察",
      url: "https://example.com/short-account-#{SecureRandom.hex(4)}",
      published_at: 1.day.ago
    )

    get account_path(@account), params: { keyword: "教育" }

    assert_response :success
    assert_select "a[href=?]", article_path(short_match)
  end

  test "account page explains a short keyword whose scan was cut off" do
    stub_class_method(Article, :with_search_timeout, ->(*) { nil }) do
      get account_path(@account), params: { keyword: "甄劢" }
    end

    assert_response :success
    assert_select "p", text: /关键词「甄劢」/
    assert_select "p", text: /超时/
  end

  test "articles index accepts a keyword of exactly 3 characters" do
    get articles_path, params: { keyword: "Art" }
    assert_response :success
    assert_select "a[href=?]", article_path(@article)
  end

  # One short term is enough to keep the indexes out of the query — the long
  # term's bitmap just feeds candidates into the short term's per-row filter —
  # so the whole keyword runs under the cap rather than being refused.
  test "articles index caps a keyword with one short term among long ones" do
    stub_class_method(Article, :with_search_timeout, ->(*) { nil }) do
      get articles_path, params: { keyword: "人工智能 甄劢" }
    end

    assert_response :success
    assert_select "p", text: /甄劢/
    assert_select "p", text: /超时/
  end

  # Kaminari's SELECT COUNT(*) has no LIMIT, so it cannot use the published_at
  # ordering index and has to evaluate the trigram OR over every article —
  # 16-28s on production. The index page now paginates with #without_count,
  # fetching one extra row instead to decide whether a next page exists.
  test "articles index issues no COUNT query" do
    assert_empty count_queries { get articles_path }
    assert_empty count_queries { get articles_path, params: { keyword: "Article" } }
    assert_empty count_queries { get articles_path, params: { keyword: "Article", platform: "wechat" } }
  end

  test "articles index paginates with prev/next links instead of total pages" do
    30.times do |i|
      @account.articles.create!(
        title: "分页文章 #{i}",
        url: "https://example.com/page-#{i}-#{SecureRandom.hex(4)}",
        published_at: i.days.ago
      )
    end

    get articles_path
    assert_response :success
    assert_select "span", text: "第 1 页"
    assert_select "p", text: "本页 25 篇"
    assert_select "a", text: "下一页"
    assert_select "a", text: "上一页", count: 0

    get articles_path, params: { page: 2 }
    assert_response :success
    assert_select "span", text: "第 2 页"
    assert_select "a", text: "上一页"
    assert_select "a", text: "下一页", count: 0
  end

  test "articles index keeps filters when paginating" do
    30.times do |i|
      @account.articles.create!(
        title: "筛选分页 #{i}",
        url: "https://example.com/filter-page-#{i}-#{SecureRandom.hex(4)}",
        published_at: i.days.ago
      )
    end

    get articles_path, params: { keyword: "筛选分页", platform: "wechat" }
    assert_response :success
    next_link = css_select("a").find { |a| a.text.strip == "下一页" }
    assert next_link, "expected a 下一页 link"
    assert_includes next_link["href"], "keyword="
    assert_includes next_link["href"], "platform=wechat"
    assert_includes next_link["href"], "page=2"
  end

  test "articles index handles a page past the end" do
    get articles_path, params: { page: 999 }
    assert_response :success
    assert_select "p", text: "没有匹配的文章"
  end

  private

  # The ILIKE statements issued while the block runs, so a test can tell a
  # keyword that was actually searched from one whose search never started.
  def search_queries
    found = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      found << sql if payload[:name] != "SCHEMA" && sql.match?(/ILIKE/i)
    end
    yield
    found
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # The SQL issued while the block runs, filtered to COUNT queries.
  def count_queries
    found = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      found << sql if payload[:name] != "SCHEMA" && sql.match?(/\bCOUNT\s*\(/i)
    end
    yield
    found
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
