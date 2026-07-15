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

    assert_redirected_to accounts_path
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

    WechatApiClient.singleton_class.alias_method :__original_search_account_for_test, :search_account
    WechatApiClient.singleton_class.define_method(:search_account) do |_keyword|
      api_response
    end

    begin
      get import_wechat_search_accounts_path, params: { keyword: "测试关键词" }
    ensure
      WechatApiClient.singleton_class.alias_method :search_account, :__original_search_account_for_test
      WechatApiClient.singleton_class.remove_method :__original_search_account_for_test
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

    assert_redirected_to import_accounts_path
    follow_redirect!
    assert_match "请输入搜索关键词", response.body
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
