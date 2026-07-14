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
end
