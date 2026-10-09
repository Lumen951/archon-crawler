require "test_helper"

class ApiPerPageTest < ActionDispatch::IntegrationTest
  # GET /api/v1/articles resolves to one of three code paths by parameter, and
  # each used to clamp per_page differently. Assert all three honour the
  # documented 1..100 / default 25 contract.
  setup do
    @user = User.create!(
      email_address: "per_page@example.com",
      password: "password123",
      password_confirmation: "password123",
      email_confirmed_at: Time.current
    )
    @token = @user.api_keys.create!(name: "per-page").token

    @account = WechatAccount.create!(fakeid: "per_page_acct", nickname: "分页号", status: :active)

    @group = @user.groups.create!(ref_key: "per-page-group")
    @group.group_accounts.create!(account: @account)

    60.times do |i|
      @account.articles.create!(
        title: "分页文章 #{i} 共同学",
        url: "https://example.com/per-page-#{i}-#{SecureRandom.hex(4)}",
        content_markdown: "共同学 正文 #{i}",
        published_at: i.days.ago
      )
    end
  end

  def auth_headers
    { "Authorization" => "Bearer #{@token}" }
  end

  def article_params(mode, extra = {})
    case mode
    when :group
      { group_ref_keys: [ "per-page-group" ], start_date: 1.year.ago.to_date.to_s, end_date: Date.today.to_s }.merge(extra)
    when :account
      { account_id: @account.id }.merge(extra)
    when :keyword
      { keyword: "共同学" }.merge(extra)
    end
  end

  # per_page=1, 10 and 50 all used to be wrong in account/keyword mode, which
  # silently raised anything below 25 up to 25.
  [ 1, 10, 25, 50 ].each do |requested|
    %i[group account keyword].each do |mode|
      test "per_page=#{requested} is honoured in #{mode} mode" do
        get "/api/v1/articles", params: article_params(mode, per_page: requested), headers: auth_headers

        assert_response :success
        json = JSON.parse(response.body)
        assert_equal requested, json["pagination"]["per_page"]
        assert_equal requested, json["articles"].length
      end
    end
  end

  %i[group account keyword].each do |mode|
    test "#{mode} mode defaults per_page to 25" do
      get "/api/v1/articles", params: article_params(mode), headers: auth_headers

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal 25, json["pagination"]["per_page"]
      assert_equal 25, json["articles"].length
    end

    test "#{mode} mode caps per_page at 100" do
      get "/api/v1/articles", params: article_params(mode, per_page: 150), headers: auth_headers

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal 100, json["pagination"]["per_page"]
    end

    # Garbage and out-of-range values fall back to the default rather than
    # reaching Kaminari as 0 or negative (which raises ZeroPerPageOperation).
    [ "0", "-5", "abc", "" ].each do |bad|
      test "#{mode} mode falls back to default for per_page=#{bad.inspect}" do
        get "/api/v1/articles", params: article_params(mode, per_page: bad), headers: auth_headers

        assert_response :success
        assert_equal 25, JSON.parse(response.body)["pagination"]["per_page"]
      end
    end

    test "#{mode} mode falls back to page 1 for a non-positive page" do
      get "/api/v1/articles", params: article_params(mode, page: 0), headers: auth_headers

      assert_response :success
      assert_equal 1, JSON.parse(response.body)["pagination"]["page"]
    end
  end

  test "per_page still pages correctly in account mode" do
    get "/api/v1/articles", params: article_params(:account, per_page: 10, page: 1), headers: auth_headers
    first_page = JSON.parse(response.body)

    get "/api/v1/articles", params: article_params(:account, per_page: 10, page: 2), headers: auth_headers
    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 2, json["pagination"]["page"]
    assert_equal 10, json["articles"].length
    assert json["pagination"]["has_next_page"]
    assert_empty json["articles"].map { |a| a["id"] } & first_page["articles"].map { |a| a["id"] }
  end

  # Kaminari's SELECT COUNT(*) has no LIMIT, so it cannot use the published_at
  # index and has to evaluate the whole trigram OR — 16-28s on production, more
  # than the page query it accompanies. All three modes now skip it and report
  # has_next_page from the extra row Kaminari fetches instead.
  test "no mode issues a COUNT query" do
    %i[group account keyword].each do |mode|
      queries = count_queries { get "/api/v1/articles", params: article_params(mode), headers: auth_headers }

      assert_response :success
      assert_empty queries, "#{mode} mode ran a COUNT"
      assert JSON.parse(response.body)["pagination"].key?("has_next_page")
    end
  end

  private

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
