require "test_helper"

module Admin
  # 活动调研通知的独立飞书默认目标：与扫码登录提醒的 feishu_receive_id 互不混用
  class SettingsEventFeishuTest < ActionDispatch::IntegrationTest
    setup do
      Option.delete_all

      @admin = User.create!(
        email_address: "event-feishu-admin@example.com",
        password: "password123",
        password_confirmation: "password123",
        role: :admin,
        email_confirmed_at: Time.current
      )
      post session_path, params: { email_address: @admin.email_address, password: "password123" }
    end

    test "settings page shows event research target separately from login target" do
      Option.event_feishu_receive_id = "oc_event"
      Option.event_feishu_receive_id_type = "chat_id"
      Option.feishu_receive_id = "oc_login"

      get admin_settings_path

      assert_response :success
      assert_match "活动调研默认推送目标", response.body
      assert_match "oc_event", response.body
      assert_match "oc_login", response.body
      assert_match "name=\"event_feishu_receive_id\"", response.body
    end

    test "updates the event research default target without touching the login target" do
      Option.feishu_receive_id = "oc_login"

      patch admin_settings_path, params: {
        event_feishu_receive_id: "oc_event",
        event_feishu_receive_id_type: "open_id"
      }

      assert_redirected_to admin_settings_path
      assert_equal "oc_event", Option.event_feishu_receive_id
      assert_equal "open_id", Option.event_feishu_receive_id_type
      assert_equal "oc_login", Option.feishu_receive_id
    end

    test "blank event target clears it but keeps the login target" do
      Option.event_feishu_receive_id = "oc_event"
      Option.feishu_receive_id = "oc_login"

      patch admin_settings_path, params: { event_feishu_receive_id: "" }

      assert_redirected_to admin_settings_path
      assert_nil Option.event_feishu_receive_id
      assert_equal "oc_login", Option.feishu_receive_id
    end

    test "rejects invalid event target type values" do
      patch admin_settings_path, params: {
        event_feishu_receive_id: "oc_event",
        event_feishu_receive_id_type: "user_id"
      }

      assert_redirected_to admin_settings_path
      assert_equal "oc_event", Option.event_feishu_receive_id
      assert_equal "chat_id", Option.event_feishu_receive_id_type
    end
  end
end
