require "test_helper"

class ProfilesLlmSettingsTest < ActionDispatch::IntegrationTest
  setup do
    Option.where(opt_key: %w[openai_api_key openai_api_key_owner_id openai_api_key_modified]).delete_all
    @user = User.create!(email_address: "llm-user@archon.tech", password: "abc123")
  end

  test "only the first contributor can replace the shared key without exposing it" do
    post session_path, params: { email_address: @user.email_address, password: "abc123" }
    get edit_profile_path
    assert_response :success
    assert_match "未添加", response.body

    patch update_llm_api_key_profile_path, params: { openai_api_key: "first-test-value" }
    assert_redirected_to edit_profile_path(anchor: "llm-settings")
    assert_equal "first-test-value", Option.openai_api_key

    delete session_path
    other = User.create!(email_address: "llm-other@archon.tech", password: "abc123")
    post session_path, params: { email_address: other.email_address, password: "abc123" }
    get edit_profile_path
    assert_match "已添加", response.body
    assert_select "input[name=openai_api_key]", count: 0
    assert_no_match "first-test-value", response.body
    patch update_llm_api_key_profile_path, params: { openai_api_key: "second-test-value" }
    assert_equal "first-test-value", Option.openai_api_key

    delete session_path
    post session_path, params: { email_address: @user.email_address, password: "abc123" }
    patch update_llm_api_key_profile_path, params: { openai_api_key: "second-test-value" }
    assert_equal "second-test-value", Option.openai_api_key
    get edit_profile_path
    assert_match "已修改", response.body
    assert_no_match "second-test-value", response.body
    patch update_llm_api_key_profile_path, params: { openai_api_key: "  " }
    assert_equal "second-test-value", Option.openai_api_key
  end

  test "an administrator cannot overwrite another user's key through settings" do
    assert_equal :added, Option.configure_llm_key!(user: @user, key: "owner-key")
    admin = User.create!(email_address: "llm-admin@archon.tech", password: "abc123", role: :admin)
    post session_path, params: { email_address: admin.email_address, password: "abc123" }
    patch admin_settings_path, params: { openai_api_key: "replacement" }
    assert_response :forbidden
    assert_equal "owner-key", Option.openai_api_key
  end

  test "legacy unowned keys can only be maintained by administrators" do
    Option.openai_api_key = "legacy-key"
    refute Option.llm_key_editable_by?(@user)
    admin = User.create!(email_address: "legacy-admin@archon.tech", password: "abc123", role: :admin)
    assert_equal :updated, Option.configure_llm_key!(user: admin, key: "new-key")
    assert_equal admin.id.to_s, Option.get("openai_api_key_owner_id")
  end

  test "anonymous users cannot update the shared key" do
    patch update_llm_api_key_profile_path, params: { openai_api_key: "anonymous-value" }
    assert_response :redirect
    assert_nil Option.openai_api_key
  end
end
