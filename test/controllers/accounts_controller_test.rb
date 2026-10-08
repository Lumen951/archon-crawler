require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email_address: "admin@example.com",
      password: "password123",
      password_confirmation: "password123",
      role: :admin,
      email_confirmed_at: Time.current
    )

    post session_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
  end

  test "imports csv upload and reports invalid rows" do
    file = Rack::Test::UploadedFile.new(
      Rails.root.join("test/fixtures/files/accounts_import.csv"),
      "text/csv"
    )

    post import_wechat_file_accounts_path, params: { json_file: file }

    assert_redirected_to accounts_path
    follow_redirect!
    assert_match "成功导入 1 个帐号（0 个重复已跳过），1 行缺少必填字段已跳过", response.body
    assert Account.exists?(fakeid: "controller_fakeid_1")
  end

  test "rejects unsupported upload types" do
    file = Rack::Test::UploadedFile.new(
      Rails.root.join("test/fixtures/files/accounts_import.txt"),
      "text/plain"
    )

    post import_wechat_file_accounts_path, params: { json_file: file }

    assert_redirected_to import_wechat_page_accounts_path
    follow_redirect!
    assert_match "仅支持 .json、.csv、.xlsx 文件", response.body
  end

  test "shows search preview from api" do
    api_response = {
      "code" => 0,
      "data" => {
        "accounts" => [
          {
            "fakeid" => "search_fakeid_1",
            "nickname" => "通过搜索导入",
            "round_head_img" => "https://example.com/avatar.png",
            "articles" => 12
          }
        ]
      }
    }

    # Stub WechatMpNativeApiClient.search_account (requires QR login session)
    WechatMpNativeApiClient.singleton_class.alias_method :__original_search_account_for_test, :search_account
    WechatMpNativeApiClient.singleton_class.define_method(:search_account) do |_keyword|
      api_response
    end
    # Also stub load_session! to bypass QR login check
    WechatMpNativeApiClient.singleton_class.alias_method :__original_load_session_for_test, :load_session!
    WechatMpNativeApiClient.singleton_class.define_method(:load_session!) do
      ["cookie_str", "token_str"]
    end

    begin
      get import_wechat_search_accounts_path, params: { keyword: "测试关键词" }
    ensure
      WechatMpNativeApiClient.singleton_class.alias_method :search_account, :__original_search_account_for_test
      WechatMpNativeApiClient.singleton_class.remove_method :__original_search_account_for_test
      WechatMpNativeApiClient.singleton_class.alias_method :load_session!, :__original_load_session_for_test
      WechatMpNativeApiClient.singleton_class.remove_method :__original_load_session_for_test
    end

    assert_response :success
    assert_match "搜索结果预览", response.body
    assert_match "通过搜索导入", response.body
  end

  test "imports selected accounts from preview" do
    post import_wechat_accounts_path, params: {
      selected_fakeids: ["search_fakeid_1"],
      accounts_data: {
        "search_fakeid_1" => {
          "nickname" => "通过搜索导入",
          "round_head_img" => "https://example.com/avatar.png",
          "total_articles" => "12"
        }
      }
    }

    assert_redirected_to accounts_path
    follow_redirect!
    assert_match "成功导入 1 个帐号（0 个重复已跳过）", response.body

    account = Account.find_by(fakeid: "search_fakeid_1")
    assert_not_nil account
    assert_equal "通过搜索导入", account.nickname
  end

  test "rejects empty keyword for search import" do
    get import_wechat_search_accounts_path, params: { keyword: "   " }

    assert_redirected_to import_wechat_page_accounts_path
    follow_redirect!
    assert_match "请输入搜索关键词", response.body
  end

  test "accepts multiple article URLs asynchronously" do
    resolver_called = false
    stub_class_method(AccountResolver, :resolve_wechat_by_url, ->(_url) { resolver_called = true }) do
      assert_enqueued_with(job: WechatUrlImportJob) do
        post import_wechat_by_url_accounts_path, params: {
          article_urls: " https://mp.weixin.qq.com/s/one\n\nhttps://mp.weixin.qq.com/s/two\nhttps://mp.weixin.qq.com/s/one "
        }
      end
    end

    assert_redirected_to wechat_url_import_task_path(WechatUrlImportTask.last)
    task = WechatUrlImportTask.last
    assert_equal 2, task.total_count
    assert_equal 2, task.items.count
    assert_equal false, resolver_called
  end

  test "rejects an empty article URL batch" do
    post import_wechat_by_url_accounts_path, params: { article_urls: " \n\n" }

    assert_redirected_to import_wechat_page_accounts_path
    follow_redirect!
    assert_match "请输入至少一个微信公众号文章链接", response.body
  end

  test "shows a compact account index" do
    account = WechatAccount.create!(
      fakeid: "compact_index_account",
      nickname: "紧凑列表帐号",
      status: :active,
      activity_score: 52,
      articles_last_7_days: 3,
      articles_last_30_days: 12,
      total_articles: 58,
      last_published_at: 2.days.ago,
      last_crawled_at: 1.day.ago,
      next_crawl_at: 1.day.from_now
    )
    first_tag = Tag.create!(name: "重点关注")
    long_tag = Tag.create!(name: "这是一个很长的标签名称，用于验证桌面列表中的截断和悬停展示")
    account.tags << [first_tag, long_tag]

    get accounts_path

    assert_response :success
    assert_select "a[href=?]", account_path(account), text: account.nickname
    assert_select ".status-badge", text: "启用"
    assert_select "td[title=?]", "活跃度评分：52。过去 7 天 3 篇，过去 30 天 12 篇，共 58 篇", text: "52"
    assert_select "td", text: /上次：1天前/
    assert_select "span[title=?]", first_tag.name, text: first_tag.name
    assert_select "span[title=?]", "#{first_tag.name}, #{long_tag.name}", text: "+1"
    assert_select "form[action=?]", crawl_account_path(account)
    assert_select "form[action=?]", toggle_status_account_path(account)
  end

  test "shows account identity details" do
    account = accounts(:one)

    get account_path(account)

    assert_response :success
    assert_select "[data-controller='inline-edit'] h1[data-inline-edit-target='display']", text: account.nickname
    assert_select "span", text: account.platform_name
    assert_select "div.w-20.h-20", text: "💬"
  end

  test "deletes account from show action" do
    account = WechatAccount.create!(fakeid: "to_delete_fakeid", nickname: "待删除帐号", status: :active)

    delete account_path(account)

    assert_redirected_to accounts_path
    follow_redirect!
    assert_match "帐号 待删除帐号 已删除", response.body
    assert_not Account.exists?(id: account.id)
  end

  test "imports websites from textarea lines" do
    post import_website_accounts_path, params: {
      urls: "DeepSeek, https://www.deepseek.com\nhttps://www.openai.com"
    }

    assert_redirected_to accounts_path(q: { type_eq: "WebsiteAccount" })
    follow_redirect!
    assert_match "成功导入 2 个帐号", response.body

    deepseek = Account.find_by(fakeid: "deepseek.com")
    assert_equal "WebsiteAccount", deepseek.type
    assert_equal "DeepSeek", deepseek.nickname
    assert_equal "https://www.deepseek.com", deepseek.metadata["url"]

    openai = Account.find_by(fakeid: "openai.com")
    assert_equal "openai.com", openai.nickname
    assert_equal "https://www.openai.com", openai.metadata["url"]
  end

  test "website import skips duplicates and reports invalid lines" do
    WebsiteAccount.create!(fakeid: "deepseek.com", nickname: "DeepSeek", metadata: { url: "https://www.deepseek.com" })

    post import_website_accounts_path, params: {
      urls: "https://www.deepseek.com\nnot a url"
    }

    assert_redirected_to accounts_path(q: { type_eq: "WebsiteAccount" })
    follow_redirect!
    assert_match "部分网址导入失败", response.body
    assert_equal 1, WebsiteAccount.count
  end

  test "listing website import enqueues rule generation" do
    assert_enqueued_with(job: GenerateWebsiteListingRuleJob) do
      post import_website_accounts_path, params: {
        urls: "Events, https://events.example.com/list",
        crawl_mode: "listing"
      }
    end

    account = WebsiteAccount.find_by!(fakeid: "events.example.com")
    assert_equal({ "mode" => "listing" }, account.crawl_rule)
  end

  test "updates a website listing crawl rule" do
    account = WebsiteAccount.create!(fakeid: "events.example.com", nickname: "Events", metadata: { url: "https://events.example.com" })
    rule = {
      mode: "listing",
      entry_urls: [ "https://events.example.com/events" ],
      item_selector: ".event-card",
      url: { selector: "a", attribute: "href" },
      title: { selector: "a" }
    }

    patch update_crawl_rule_account_path(account), params: { crawl_rule_json: rule.to_json }

    assert_redirected_to account_path(account)
    assert_equal "listing", account.reload.crawl_mode
    assert_equal [ "https://events.example.com/events" ], account.crawl_rule["entry_urls"]
  end

  test "rejects invalid website crawl rule JSON" do
    account = WebsiteAccount.create!(fakeid: "rules.example.com", nickname: "Rules", metadata: { url: "https://rules.example.com" })

    patch update_crawl_rule_account_path(account), params: { crawl_rule_json: "{" }

    assert_redirected_to account_path(account)
    assert_equal "sitemap", account.reload.crawl_mode
  end
end
