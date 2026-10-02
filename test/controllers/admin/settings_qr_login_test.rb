require "test_helper"

module Admin
  class SettingsQrLoginTest < ActionDispatch::IntegrationTest
    setup do
      Option.delete_all

      @admin = User.create!(
        email_address: "qr-admin@example.com",
        password: "password123",
        password_confirmation: "password123",
        role: :admin,
        email_confirmed_at: Time.current
      )
      post session_path, params: { email_address: @admin.email_address, password: "password123" }
    end

    # 2026-10 起其余 provider 从 UI 隐藏，设置页只渲染 weread_native 的扫码面板
    # （partial / Stimulus controller 与已下线的平台共用）
    test "settings page renders the QR panel for weread_native only" do
      get admin_settings_path

      assert_response :success
      assert_match 'data-qr-login-provider-value="weread_native"', response.body
      assert_no_match 'data-qr-login-provider-value="wechat_mp"', response.body
      assert_no_match 'data-qr-login-provider-value="weread"', response.body
      assert_match "约 2 小时", response.body, "有效期文案应由 Option::WEREAD_NATIVE_SESSION_TTL 驱动"
      assert_no_match(/WechatMpQrPoller|WereadQrPoller/, response.body, "内联轮询脚本应已被 Stimulus 取代")
    end

    test "request returns an inline data-uri QR and a cache token" do
      qr = -> { { handle: { "uuid" => "u1", "cookie_jar" => {} }, image_bytes: "PNGDATA", image_mime: "image/png" } }

      with_memory_cache do
        stub_class_method(QrLogin::WechatMp, :start, qr) do
          post qr_login_request_admin_settings_path, params: { provider: "wechat_mp" }
        end
      end

      assert_response :success
      body = response.parsed_body
      assert_equal "waiting", body["status"]
      assert body["token"].present?
      # 二维码内联，不依赖第三方渲染服务
      assert_equal "data:image/png;base64,#{Base64.strict_encode64('PNGDATA')}", body["image_src"]
    end

    test "request reports provider failures as 422 instead of 500" do
      boom = -> { raise QrLogin::Error, "转发服务未返回二维码链接" }

      with_memory_cache do
        stub_class_method(QrLogin::Weread, :start, boom) do
          post qr_login_request_admin_settings_path, params: { provider: "weread" }
        end
      end

      assert_response :unprocessable_entity
      assert_match "转发服务未返回二维码链接", response.parsed_body["error"]
    end

    test "status round-trips the handle so a refreshed cookie jar survives polling" do
      start = -> { { handle: { "uuid" => "u1", "cookie_jar" => { "a" => "1" } }, image_bytes: "P", image_mime: "image/png" } }
      seen_jars = []
      poll = proc do |handle, **|
        seen_jars << handle["cookie_jar"]
        { status: :scanned, message: "已扫码", handle: handle.merge("cookie_jar" => { "a" => "2" }), result: nil }
      end

      with_memory_cache do
        stub_class_methods(QrLogin::WechatMp, start: start, poll: poll) do
          post qr_login_request_admin_settings_path, params: { provider: "wechat_mp" }
          token = response.parsed_body["token"]

          get qr_login_status_admin_settings_path, params: { token: token }
          assert_equal "scanned", response.parsed_body["status"]

          get qr_login_status_admin_settings_path, params: { token: token }
          assert_equal "scanned", response.parsed_body["status"]
        end
      end

      assert_equal [ { "a" => "1" }, { "a" => "2" } ], seen_jars,
                   "第二次轮询必须带上第一次刷新后的 cookie jar"
    end

    test "status persists the session on success and burns the token" do
      start = -> { { handle: { "uuid" => "u1", "cookie_jar" => {} }, image_bytes: "P", image_mime: "image/png" } }
      success = proc do |handle, **|
        { status: :success, message: "", handle: handle,
          result: { cookie_str: "c=1", token: "tok", account_info: { nickname: "某公众号" } } }
      end

      with_memory_cache do
        stub_class_methods(QrLogin::WechatMp, start: start, poll: success) do
          post qr_login_request_admin_settings_path, params: { provider: "wechat_mp" }
          token = response.parsed_body["token"]

          get qr_login_status_admin_settings_path, params: { token: token }
          assert_equal "success", response.parsed_body["status"]
          assert_match "某公众号", response.parsed_body["message"]

          # 用过的 token 立刻失效，防止重放
          get qr_login_status_admin_settings_path, params: { token: token }
          assert_equal "expired", response.parsed_body["status"]
        end
      end

      assert_equal "c=1", Option.wechat_mp_cookie
      assert_equal "tok", Option.wechat_mp_token
      assert Option.wechat_mp_session_valid?
    end

    test "status without a live token reports expired rather than erroring" do
      with_memory_cache do
        get qr_login_status_admin_settings_path, params: { token: "does-not-exist" }
      end

      assert_response :success
      assert_equal "expired", response.parsed_body["status"]
    end

    test "non-admins cannot drive the QR login endpoints" do
      delete session_path
      plain = User.create!(
        email_address: "plain@example.com",
        password: "password123",
        password_confirmation: "password123",
        role: :user,
        email_confirmed_at: Time.current
      )
      post session_path, params: { email_address: plain.email_address, password: "password123" }

      post qr_login_request_admin_settings_path, params: { provider: "wechat_mp" }
      assert_response :redirect
      assert_not_equal admin_settings_path, path
    end
  end
end
