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

  test "should link back to account" do
    get article_path(@article)
    assert_response :success
    assert_select "a[href=?]", account_path(@article.account)
  end

  test "shows account identity on article index and show" do
    @account.update!(round_head_img: "https://example.com/avatar.png")

    get articles_path
    assert_response :success
    assert_select "a[href=?] img[src=?][alt=?]", account_path(@account), @account.round_head_img, @account.nickname
    assert_select "span", text: @account.platform_name

    get article_path(@article)
    assert_response :success
    assert_select "a[href=?] img[src=?][alt=?]", account_path(@account), @account.round_head_img, @account.nickname
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
end
