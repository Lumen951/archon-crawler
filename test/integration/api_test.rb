require "test_helper"

class ApiTest < ActionDispatch::IntegrationTest
  DEBUG = ENV["DEBUG"] == "true"

  setup do
    @user = User.create!(
      email_address: "api_test@example.com",
      password: "password123",
      password_confirmation: "password123",
      email_confirmed_at: Time.current
    )

    @api_key = @user.api_keys.create!(name: "Test API Key")
    @token = @api_key.token

    # Create test accounts
    @wechat_account = WechatAccount.create!(
      fakeid: "fakeid_wechat_123",
      nickname: "北京大学",
      status: :active,
      total_articles: 0
    )

    @rednote_account = RednoteAccount.create!(
      fakeid: "6229d4850000000021021d46",
      nickname: "北京大学小红书",
      status: :active,
      total_articles: 0
    )

    @twitter_account = TwitterAccount.create!(
      fakeid: "1234567890",
      nickname: "PKU1898",
      status: :active,
      total_articles: 0
    )

    # Create test articles with unique URLs
    @article1 = @wechat_account.articles.create!(
      title: "北京大学2026年招生简章",
      url: "https://example.com/article-wechat-#{SecureRandom.hex(8)}",
      content_markdown: "# 北京大学2026年招生简章\n\n这是测试内容",
      content_html: "<h1>北京大学2026年招生简章</h1><p>这是测试内容</p>",
      published_at: Time.current
    )

    @article2 = @rednote_account.articles.create!(
      title: "北京大学新生入学指南",
      url: "https://example.com/article-rednote-#{SecureRandom.hex(8)}",
      content_markdown: "# 新生入学指南\n\n这是测试内容",
      content_html: "<h1>新生入学指南</h1><p>这是测试内容</p>",
      published_at: 1.day.ago
    )
  end

  # ============================================================================
  # POST /groups
  # ============================================================================

  test "POST /groups - success with all accounts found" do
    debug_log("测试: 创建分组 - 所有帐号找到")

    params = {
      ref_key: "pku",
      accounts: [
        { source: "wechat", id: "fakeid_wechat_123" },
        { source: "rednote", id: "6229d4850000000021021d46" },
        { source: "twitter", id: "1234567890" }
      ]
    }

    post "/api/v1/groups",
      params: params.to_json,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :created
    json = JSON.parse(response.body)

    assert_equal "pku", json["group"]["ref_key"]
    assert_equal @user.id, json["group"]["user_id"]
    assert_equal 3, json["accounts"].length
    assert_empty json["errors"]

    # Verify all accounts are in the group
    group = Group.find_by(ref_key: "pku", user: @user)
    assert_equal 3, group.accounts.count
  end

  test "POST /groups - partial success with some accounts not found" do
    debug_log("测试: 创建分组 - 部分帐号未找到")

    params = {
      ref_key: "mixed",
      accounts: [
        { source: "wechat", id: "fakeid_wechat_123" },
        { source: "rednote", id: "nonexistent_rednote_id_12345" }
      ]
    }

    post "/api/v1/groups",
      params: params.to_json,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :created
    json = JSON.parse(response.body)

    assert_equal "mixed", json["group"]["ref_key"]
    assert_equal 1, json["accounts"].length
    assert_equal "wechat", json["accounts"][0]["source"]
    assert_equal 1, json["errors"].length
    assert_equal "rednote", json["errors"][0]["source"]
    # The error could be about API key not configured or account not found
    assert json["errors"][0]["error"].present?
  end

  test "POST /groups - error invalid ref_key format" do
    debug_log("测试: 创建分组 - ref_key 格式无效")

    params = {
      ref_key: "invalid ref_key!",
      accounts: []
    }

    post "/api/v1/groups",
      params: params.to_json,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["error"], "ref_key 只能包含字母、数字、下划线和连字符"
  end

  test "POST /groups - error duplicate ref_key" do
    debug_log("测试: 创建分组 - ref_key 重复")

    # Create first group
    @user.groups.create!(ref_key: "duplicate")

    params = {
      ref_key: "duplicate",
      accounts: []
    }

    post "/api/v1/groups",
      params: params.to_json,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["error"], "该用户已存在相同的 ref_key"
  end

  test "POST /groups - error missing authorization" do
    debug_log("测试: 创建分组 - 缺少认证")

    params = {
      ref_key: "test",
      accounts: []
    }

    post "/api/v1/groups",
      params: params.to_json,
      headers: { "Content-Type" => "application/json" }

    debug_response(response, request_params: params)

    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal "缺少 Authorization header", json["error"]
  end

  test "POST /groups - error invalid API key" do
    debug_log("测试: 创建分组 - 无效的 API key")

    params = {
      ref_key: "test",
      accounts: []
    }

    post "/api/v1/groups",
      params: params.to_json,
      headers: { "Authorization" => "Bearer invalid_token", "Content-Type" => "application/json" }

    debug_response(response, request_params: params)

    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert_equal "无效的 API key", json["error"]
  end

  # ============================================================================
  # PATCH /groups/{ref_key}
  # ============================================================================

  test "PATCH /groups/:ref_key - success with all accounts found" do
    debug_log("测试: 更新分组 - 所有帐号找到")

    group = @user.groups.create!(ref_key: "update-test")
    group.group_accounts.create!(account: @wechat_account)

    params = {
      accounts: [
        { source: "wechat", id: "fakeid_wechat_123" },
        { source: "rednote", id: "6229d4850000000021021d46" },
        { source: "twitter", id: "1234567890" }
      ]
    }

    patch "/api/v1/groups/update-test",
      params: params.to_json,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal "update-test", json["group"]["ref_key"]
    assert_equal 3, json["accounts"].length
    assert_empty json["errors"]

    # Verify group accounts were replaced
    group.reload
    assert_equal 3, group.accounts.count
  end

  test "PATCH /groups/:ref_key - partial success with some accounts not found" do
    debug_log("测试: 更新分组 - 部分帐号未找到")

    group = @user.groups.create!(ref_key: "update-partial")

    params = {
      accounts: [
        { source: "wechat", id: "fakeid_wechat_123" },
        { source: "rednote", id: "invalid_id" }
      ]
    }

    patch "/api/v1/groups/update-partial",
      params: params.to_json,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 1, json["accounts"].length
    assert_equal 1, json["errors"].length
  end

  test "PATCH /groups/:ref_key - error group not found" do
    debug_log("测试: 更新分组 - 分组未找到")

    params = {
      accounts: []
    }

    patch "/api/v1/groups/nonexistent",
      params: params.to_json,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :not_found
    json = JSON.parse(response.body)
    assert_includes json["error"], "分组未找到"
  end

  # ============================================================================
  # GET /articles
  # ============================================================================

  test "GET /articles - success with articles" do
    debug_log("测试: 查询文章 - 有文章")

    group = @user.groups.create!(ref_key: "article-test")
    group.group_accounts.create!(account: @wechat_account)
    group.group_accounts.create!(account: @rednote_account)

    params = {
      group_ref_keys: ["article-test"],
      start_date: 1.week.ago.to_date.to_s,
      end_date: Date.today.to_s
    }

    get "/api/v1/articles",
      params: params,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :success
    json = JSON.parse(response.body)

    assert json["articles"].length > 0
    assert json["pagination"]["total_count"] > 0
    assert json["pagination"]["page"] == 1

    # Verify article structure
    article = json["articles"].first
    assert article["id"].present?
    assert article["title"].present?
    assert article["url"].present?
    assert article["content"].present?
    assert article["published_at"].present?
    assert article["group_ref_key"].present?
    assert article["account"]["id"].present?
    assert article["account"]["source"].present?
    assert article["account"]["name"].present?
  end

  test "GET /articles - success with no articles" do
    debug_log("测试: 查询文章 - 无文章")

    group = @user.groups.create!(ref_key: "empty-group")

    params = {
      group_ref_keys: ["empty-group"],
      start_date: 1.week.ago.to_date.to_s,
      end_date: Date.today.to_s
    }

    get "/api/v1/articles",
      params: params,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :success
    json = JSON.parse(response.body)

    assert_empty json["articles"]
    assert_equal 0, json["pagination"]["total_count"]
    assert_equal 0, json["pagination"]["total_pages"]
  end

  test "GET /articles - success with platform filter" do
    debug_log("测试: 查询文章 - 使用平台筛选")

    group = @user.groups.create!(ref_key: "filter-test")
    group.group_accounts.create!(account: @wechat_account)
    group.group_accounts.create!(account: @rednote_account)

    params = {
      group_ref_keys: ["filter-test"],
      start_date: 1.week.ago.to_date.to_s,
      end_date: Date.today.to_s,
      source: "wechat"
    }

    get "/api/v1/articles",
      params: params,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :success
    json = JSON.parse(response.body)

    # Should only return wechat articles
    json["articles"].each do |article|
      assert_equal "wechat", article["account"]["source"]
    end
  end

  test "GET /articles - success with pagination" do
    debug_log("测试: 查询文章 - 分页")

    group = @user.groups.create!(ref_key: "pagination-test")
    group.group_accounts.create!(account: @wechat_account)
    group.group_accounts.create!(account: @rednote_account)

    params = {
      group_ref_keys: ["pagination-test"],
      start_date: 1.week.ago.to_date.to_s,
      end_date: Date.today.to_s,
      page: 1,
      per_page: 1
    }

    get "/api/v1/articles",
      params: params,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 1, json["articles"].length
    assert_equal 1, json["pagination"]["per_page"]
    assert json["pagination"]["total_count"] > 1
    assert json["pagination"]["total_pages"] > 1
  end

  test "GET /articles - keyword search in account mode" do
    debug_log("测试: 查询文章 - 账号模式关键词搜索")

    params = {
      account_id: @wechat_account.id,
      keyword: "招生简章"
    }

    get "/api/v1/articles",
      params: params,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :success
    json = JSON.parse(response.body)

    titles = json["articles"].map { |a| a["title"] }
    assert_includes titles, @article1.title
    assert_not_includes titles, @article2.title

    # Search matches body content too
    params = { account_id: @wechat_account.id, keyword: "这是测试内容" }
    get "/api/v1/articles", params: params, headers: auth_headers
    assert_response :success
    assert JSON.parse(response.body)["articles"].any? { |a| a["title"] == @article1.title }

    # No match
    params = { account_id: @wechat_account.id, keyword: "不存在的关键词xyz" }
    get "/api/v1/articles", params: params, headers: auth_headers
    assert_response :success
    assert_empty JSON.parse(response.body)["articles"]
  end

  test "GET /articles - keyword search in group mode" do
    debug_log("测试: 查询文章 - 分组模式关键词搜索")

    group = @user.groups.create!(ref_key: "keyword-test")
    group.group_accounts.create!(account: @wechat_account)
    group.group_accounts.create!(account: @rednote_account)

    params = {
      group_ref_keys: ["keyword-test"],
      start_date: 1.week.ago.to_date.to_s,
      end_date: Date.today.to_s,
      keyword: "新生入学指南"
    }

    get "/api/v1/articles",
      params: params,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :success
    json = JSON.parse(response.body)

    titles = json["articles"].map { |a| a["title"] }
    assert_includes titles, @article2.title
    assert_not_includes titles, @article1.title
  end

  test "GET /articles - global keyword search without account or group" do
    debug_log("测试: 查询文章 - 全局关键词搜索")

    params = { keyword: "招生简章" }
    get "/api/v1/articles", params: params, headers: auth_headers

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal "招生简章", json["keyword"]
    titles = json["articles"].map { |article| article["title"] }
    assert_includes titles, @article1.title
    assert_not_includes titles, @article2.title

    article = json["articles"].find { |entry| entry["title"] == @article1.title }
    assert_equal @wechat_account.id, article.dig("account", "id")
    assert_equal @wechat_account.fakeid, article.dig("account", "fakeid")
    assert_equal "wechat", article.dig("account", "platform")
  end

  test "GET /articles - global keyword search filters by platform and date" do
    params = {
      keyword: "新生入学指南",
      platform: "rednote",
      start_date: 1.week.ago.to_date.to_s,
      end_date: Date.today.to_s
    }

    get "/api/v1/articles", params: params, headers: auth_headers

    assert_response :success
    json = JSON.parse(response.body)
    assert_includes json["articles"].map { |article| article["title"] }, @article2.title
    assert json["articles"].all? { |article| article.dig("account", "platform") == "rednote" }
  end

  test "GET /articles - global keyword search rejects invalid platform" do
    get "/api/v1/articles", params: { keyword: "招生简章", platform: "invalid_platform" }, headers: auth_headers

    assert_response :bad_request
    assert_includes JSON.parse(response.body)["error"], "不支持的平台"
  end

  test "GET /articles - error missing group_ref_keys" do
    debug_log("测试: 查询文章 - 缺少 group_ref_keys")

    params = {
      start_date: 1.week.ago.to_date.to_s,
      end_date: Date.today.to_s
    }

    get "/api/v1/articles",
      params: params,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_includes json["error"], "group_ref_keys 不能为空"
  end

  test "GET /articles - error invalid date range" do
    debug_log("测试: 查询文章 - 日期范围无效")

    params = {
      group_ref_keys: ["test"],
      start_date: "invalid-date",
      end_date: "2026-07-15"
    }

    get "/api/v1/articles",
      params: params,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_includes json["error"], "日期格式无效"
  end

  test "GET /articles - error missing date range" do
    debug_log("测试: 查询文章 - 缺少日期范围")

    params = {
      group_ref_keys: ["test"]
    }

    get "/api/v1/articles",
      params: params,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_includes json["error"], "start_date 和 end_date 不能为空"
  end

  test "GET /articles - error invalid platform filter" do
    debug_log("测试: 查询文章 - 平台筛选无效")

    group = @user.groups.create!(ref_key: "platform-filter-test")
    group.group_accounts.create!(account: @wechat_account)

    params = {
      group_ref_keys: ["platform-filter-test"],
      start_date: 1.week.ago.to_date.to_s,
      end_date: Date.today.to_s,
      source: "invalid_platform"
    }

    get "/api/v1/articles",
      params: params,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_includes json["error"], "不支持的平台"
  end

  test "GET /articles - error no groups found" do
    debug_log("测试: 查询文章 - 未找到分组")

    params = {
      group_ref_keys: ["nonexistent"],
      start_date: 1.week.ago.to_date.to_s,
      end_date: Date.today.to_s
    }

    get "/api/v1/articles",
      params: params,
      headers: auth_headers

    debug_response(response, request_params: params)

    assert_response :not_found
    json = JSON.parse(response.body)
    assert_includes json["error"], "未找到指定的分组"
  end

  # ============================================================================
  # GET /groups
  # ============================================================================

  test "GET /groups - success" do
    debug_log("测试: 获取分组列表")

    @user.groups.create!(ref_key: "group1")
    @user.groups.create!(ref_key: "group2")

    get "/api/v1/groups",
      headers: auth_headers

    debug_response(response)

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 2, json["groups"].length
    assert json["groups"][0]["ref_key"].present?
    assert json["groups"][0]["id"].present?
    assert json["groups"][0]["accounts_count"].present?
  end

  # ============================================================================
  # GET /groups/:ref_key
  # ============================================================================

  test "GET /groups/:ref_key - success" do
    debug_log("测试: 获取分组详情")

    group = @user.groups.create!(ref_key: "detail-test")
    group.group_accounts.create!(account: @wechat_account)

    get "/api/v1/groups/detail-test",
      headers: auth_headers

    debug_response(response)

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal "detail-test", json["group"]["ref_key"]
    assert_equal 1, json["accounts"].length
    assert_equal "wechat", json["accounts"][0]["source"]
  end

  test "GET /groups/:ref_key - error not found" do
    debug_log("测试: 获取分组详情 - 未找到")

    get "/api/v1/groups/nonexistent",
      headers: auth_headers

    debug_response(response)

    assert_response :not_found
    json = JSON.parse(response.body)
    assert_includes json["error"], "分组未找到"
  end

  # ============================================================================
  # DELETE /groups/:ref_key
  # ============================================================================

  test "DELETE /groups/:ref_key - success" do
    debug_log("测试: 删除分组")

    group = @user.groups.create!(ref_key: "delete-test")

    delete "/api/v1/groups/delete-test",
      headers: auth_headers

    debug_response(response)

    assert_response :success
    json = JSON.parse(response.body)
    assert_includes json["message"], "分组已删除"

    # Verify group was deleted
    assert_nil Group.find_by(ref_key: "delete-test", user: @user)
  end

  test "DELETE /groups/:ref_key - error not found" do
    debug_log("测试: 删除分组 - 未找到")

    delete "/api/v1/groups/nonexistent",
      headers: auth_headers

    debug_response(response)

    assert_response :not_found
    json = JSON.parse(response.body)
    assert_includes json["error"], "分组未找到"
  end

  private

  def auth_headers
    {
      "Authorization" => "Bearer #{@token}",
      "Content-Type" => "application/json"
    }
  end

  def debug_log(message)
    return unless DEBUG
    puts "\n#{'=' * 80}"
    puts "  #{message}"
    puts "#{'=' * 80}"
  end

  def debug_response(response, request_params: nil)
    return unless DEBUG

    puts "\n  请求: #{request.method} #{request.path}"
    puts "  状态码: #{response.status}"

    if request_params.present?
      puts "\n  请求参数:"
      puts JSON.pretty_generate(request_params)
    end

    puts "\n  响应:"
    begin
      json = JSON.parse(response.body)
      puts JSON.pretty_generate(json)
    rescue JSON::ParserError
      puts response.body
    end

    puts "\n#{'-' * 80}"
  end
end
