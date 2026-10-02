require "test_helper"
require "tmpdir"

module Admin
  class SettingsBrowserLoginTest < ActionDispatch::IntegrationTest
    setup do
      Option.delete_all

      @admin = User.create!(
        email_address: "browser-admin@example.com",
        password: "password123",
        password_confirmation: "password123",
        role: :admin,
        email_confirmed_at: Time.current
      )
      post session_path, params: { email_address: @admin.email_address, password: "password123" }
    end

    # 2026-10 起其余 provider 从 UI 隐藏，远程登录区块只保留 weread_native
    #（rednote_web 是独立平台，不受影响）
    test "settings page renders remote-browser login blocks for the visible platforms" do
      get admin_settings_path

      assert_response :success
      assert_match 'data-browser-login-provider-value="rednote_web"', response.body
      assert_match 'data-browser-login-provider-value="weread_native"', response.body
      assert_no_match 'data-browser-login-provider-value="wechat_mp"', response.body
    end

    test "start returns the session handle from the session manager" do
      start = ->(provider) do
        { session_id: "s1", provider: provider, label: "微信公众号平台",
          resumed: false, logged_in: false, viewport: { width: 1280, height: 800 } }
      end

      stub_class_method(BrowserLogin::Session, :start, start) do
        post browser_login_start_admin_settings_path, params: { provider: "wechat_mp" }
      end

      assert_response :success
      body = response.parsed_body
      assert_equal "s1", body["session_id"]
      assert_equal false, body["resumed"]
    end

    test "start reports provider failures as 422 instead of 500" do
      boom = ->(_provider) { raise BrowserLogin::Error, "未找到 Chrome/Chromium 可执行文件" }

      stub_class_method(BrowserLogin::Session, :start, boom) do
        post browser_login_start_admin_settings_path, params: { provider: "wechat_mp" }
      end

      assert_response :unprocessable_entity
      assert_match "未找到 Chrome", response.parsed_body["error"]
    end

    test "unknown provider is rejected before any browser is touched" do
      post browser_login_start_admin_settings_path, params: { provider: "nope" }

      assert_response :unprocessable_entity
      assert_match "未知的远程登录平台", response.parsed_body["error"]
    end

    # 设置页标签页跨部署存留时页面 token 可能与服务端会话对不上（生产踩过：
    # 422 HTML 让前端只报 "Unexpected token '<'"），这四个接口豁免 CSRF
    test "browser login endpoints are exempt from the authenticity token check" do
      start = ->(provider) do
        { session_id: "s1", provider: provider, label: "微信公众号平台",
          resumed: false, logged_in: false, viewport: { width: 1280, height: 800 } }
      end

      old = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      stub_class_method(BrowserLogin::Session, :start, start) do
        post browser_login_start_admin_settings_path, params: { provider: "wechat_mp" },
             headers: { "X-CSRF-Token" => "stale-token" }
      end

      assert_response :success, "假 token 也必须到达 action，而不是被 CSRF 拦下"
      assert_equal "s1", response.parsed_body["session_id"]
    ensure
      ActionController::Base.allow_forgery_protection = old
    end

    # 其余接口不豁免：XHR 的 CSRF 失败返回可读 JSON（而不是 422 HTML 页），
    # 非 XHR 保持 Rails 默认的 422 HTML 行为
    test "csrf failure on other endpoints returns readable json for xhr" do
      old = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true

      post qr_login_request_admin_settings_path, params: { provider: "wechat_mp" },
           headers: { "X-Requested-With" => "XMLHttpRequest", "X-CSRF-Token" => "stale-token" }
      assert_response :unprocessable_entity
      assert_equal "application/json", response.media_type
      assert_match "页面已过期", response.parsed_body["error"]

      post qr_login_request_admin_settings_path, params: { provider: "wechat_mp" },
           headers: { "X-CSRF-Token" => "stale-token" }
      assert_response :unprocessable_entity
      assert_not_equal "application/json", response.media_type, "非 XHR 保持默认 HTML 页"
    ensure
      ActionController::Base.allow_forgery_protection = old
    end

    test "frame returns the screenshot and login status" do
      frame = lambda do |session_id, force_save: false|
        { session_id: session_id, image: "FRAMEDATA", image_mime: "image/jpeg",
          url: "https://mp.weixin.qq.com/", logged_in: true, saved: force_save,
          identity: "测试号", save_error: nil, message: "已保存登录态（测试号）" }
      end

      stub_class_method(BrowserLogin::Session, :frame, frame) do
        get browser_login_frame_admin_settings_path, params: { session_id: "s1", force_save: "1" }
      end

      assert_response :success
      body = response.parsed_body
      assert_equal "FRAMEDATA", body["image"]
      assert_equal true, body["saved"], "force_save=1 应透传给 Session.frame"
    end

    test "frame without a live session reports expired rather than erroring" do
      get browser_login_frame_admin_settings_path, params: { session_id: "does-not-exist" }

      assert_response :success
      assert_equal "expired", response.parsed_body["status"]
    end

    test "interact forwards the mapped event to the session" do
      seen = []
      interact = lambda do |_session_id, event|
        seen << event
        { ok: true }
      end

      stub_class_method(BrowserLogin::Session, :interact, interact) do
        post browser_login_interact_admin_settings_path,
             params: { session_id: "s1", event: { type: "click", x: 12.5, y: 33.5 } }.to_json,
             headers: { "Content-Type" => "application/json" }
      end

      assert_response :success
      assert_equal "click", seen.last[:type]
      assert_in_delta 12.5, seen.last[:x], 0.001
    end

    test "non-admins cannot drive the browser login endpoints" do
      delete session_path
      plain = User.create!(
        email_address: "browser-plain@example.com",
        password: "password123",
        password_confirmation: "password123",
        role: :user,
        email_confirmed_at: Time.current
      )
      post session_path, params: { email_address: plain.email_address, password: "password123" }

      post browser_login_start_admin_settings_path, params: { provider: "wechat_mp" }
      assert_response :redirect
      assert_not_equal admin_settings_path, path
    end

    # 前端 fetch 跟随 302 会拿到登录页 HTML，resp.json() 直接报
    # "Unexpected token '<'"（生产踩过）；XHR 必须拿到 401 JSON
    test "unauthenticated XHR start returns 401 json instead of the login page" do
      delete session_path

      post browser_login_start_admin_settings_path, params: { provider: "wechat_mp" },
           headers: { "X-Requested-With" => "XMLHttpRequest" }

      assert_response :unauthorized
      assert_equal "application/json", response.media_type
      assert_match "登录已过期", response.parsed_body["error"]
    end

    test "non-admin XHR start returns 401 json instead of a redirect" do
      delete session_path
      plain = User.create!(
        email_address: "browser-xhr@example.com",
        password: "password123",
        password_confirmation: "password123",
        role: :user,
        email_confirmed_at: Time.current
      )
      post session_path, params: { email_address: plain.email_address, password: "password123" }

      post browser_login_start_admin_settings_path, params: { provider: "wechat_mp" },
           headers: { "X-Requested-With" => "XMLHttpRequest" }

      assert_response :unauthorized
      assert_equal "application/json", response.media_type
      assert_match "没有权限", response.parsed_body["error"]
    end

    test "rednote_web_logout clears the stored cookie session" do
      Option.rednote_web_session_started!(cookie: "web_session=abc")

      post rednote_web_logout_admin_settings_path

      assert_response :redirect
      assert_nil Option.rednote_web_cookie
      assert_not Option.rednote_web_session_valid?
    end

    test "headed mode toggle is persisted through the settings form" do
      patch admin_settings_path, params: { browser_login_headed: "1" }
      assert Option.browser_login_headed?

      patch admin_settings_path, params: { browser_login_headed: "0" }
      assert_not Option.browser_login_headed?
    end

    test "login browser proxy is persisted and clearable" do
      patch admin_settings_path, params: { browser_login_proxy: "http://127.0.0.1:7890" }
      assert_equal "http://127.0.0.1:7890", Option.browser_login_proxy

      patch admin_settings_path, params: { browser_login_proxy: "" }
      assert_nil Option.browser_login_proxy
    end

    test "content download browser fallback toggle is persisted" do
      patch admin_settings_path, params: { wechat_content_browser_fallback: "0" }
      assert_not Option.wechat_content_browser_fallback_enabled?

      patch admin_settings_path, params: { wechat_content_browser_fallback: "1" }
      assert Option.wechat_content_browser_fallback_enabled?
    end

    test "browser login section and rednote web panel render on the settings page" do
      get admin_settings_path

      assert_response :success
      assert_match "远程浏览器登录", response.body
      assert_match 'id="browser-login"', response.body
      assert_match 'id="rednote_web_panel"', response.body
      assert_match 'name="wechat_content_browser_fallback"', response.body
    end
  end
end
