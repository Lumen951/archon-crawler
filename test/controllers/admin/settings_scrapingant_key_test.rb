require "test_helper"

module Admin
  class SettingsScrapingAntKeyTest < ActionDispatch::IntegrationTest
    setup do
      Option.delete_all

      @admin = User.create!(
        email_address: "scrapingant-admin@example.com",
        password: "password123",
        password_confirmation: "password123",
        role: :admin,
        email_confirmed_at: Time.current
      )
      post session_path, params: { email_address: @admin.email_address, password: "password123" }
    end

    test "settings page renders the render fallback card and warns while unconfigured" do
      get admin_settings_path

      assert_response :success
      assert_match 'id="website-render"', response.body
      assert_match "未配置 ScrapingAnt API Key", response.body
    end

    test "saving the key persists it and shows it masked afterwards" do
      patch admin_settings_path, params: { scrapingant_api_key: "sa-test-key-123456" }

      assert_redirected_to admin_settings_path
      assert_equal "sa-test-key-123456", Option.scrapingant_api_key

      follow_redirect!
      assert_match "ScrapingAnt API Key 更新成功", response.body
      assert_match "sa-t****3456", response.body
      assert_no_match "未配置 ScrapingAnt API Key", response.body
    end

    test "a blank submission keeps the existing key" do
      Option.scrapingant_api_key = "keep-me"

      patch admin_settings_path, params: { scrapingant_api_key: "" }

      assert_equal "keep-me", Option.scrapingant_api_key
    end

    test "saving render fallback providers persists them" do
      patch admin_settings_path, params: { website_render_fallbacks: [ "local_headless", "scrapingant" ] }

      assert_redirected_to admin_settings_path
      assert_equal [ "local_headless", "scrapingant" ], Option.website_render_fallbacks

      follow_redirect!
      assert_match "渲染兜底配置更新成功", response.body
    end

    test "unchecked fallbacks are persisted as empty array" do
      Option.set("website_render_fallbacks", [ "local_headless", "scrapingant" ].to_json)

      patch admin_settings_path, params: { website_render_fallbacks: [] }

      assert_redirected_to admin_settings_path
      assert_equal [], Option.website_render_fallbacks
    end

    test "invalid fallback providers are filtered out" do
      patch admin_settings_path, params: { website_render_fallbacks: [ "local_headless", "invalid_provider", "scrapingant" ] }

      assert_redirected_to admin_settings_path
      assert_equal [ "local_headless", "scrapingant" ], Option.website_render_fallbacks
    end
  end
end
