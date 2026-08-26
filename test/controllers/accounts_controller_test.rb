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

  test "deletes account from show action" do
    account = WechatAccount.create!(fakeid: "to_delete_fakeid", nickname: "待删除帐号", status: :active)

    delete account_path(account)

    assert_redirected_to accounts_path
    follow_redirect!
    assert_match "帐号 待删除帐号 已删除", response.body
    assert_not Account.exists?(id: account.id)
  end
end
