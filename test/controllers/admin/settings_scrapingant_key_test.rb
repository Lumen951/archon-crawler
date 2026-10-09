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

    test "settings page renders the event research search settings" do
      get admin_settings_path

      assert_response :success
      assert_match 'id="event-search"', response.body
      assert_match "活动调研搜索", response.body
      assert_match "Tavily API Key", response.body
      assert_match "Serper API Key", response.body
      assert_match "TAVILY_API_KEY", response.body
      assert_match "SERPER_API_KEY", response.body
    end

    test "saving event research search settings persists provider and both keys" do
      patch admin_settings_path, params: {
        event_search_provider: "serper",
        tavily_api_key: "tv-test-key",
        serper_api_key: "sp-test-key"
      }

      assert_redirected_to admin_settings_path
      assert_equal "serper", Option.event_search_provider
      assert_equal "tv-test-key", Option.tavily_api_key
      assert_equal "sp-test-key", Option.serper_api_key

      follow_redirect!
      assert_match "活动调研搜索", response.body
      assert_match "sp-t****-key", response.body
      assert_match "tv-t****-key", response.body
    end

    test "blank event research keys keep existing values" do
      Option.event_search_provider = "serper"
      Option.tavily_api_key = "keep-tavily"
      Option.serper_api_key = "keep-serper"

      patch admin_settings_path, params: {
        event_search_provider: "tavily",
        tavily_api_key: "",
        serper_api_key: ""
      }

      assert_equal "tavily", Option.event_search_provider
      assert_equal "keep-tavily", Option.tavily_api_key
      assert_equal "keep-serper", Option.serper_api_key
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
