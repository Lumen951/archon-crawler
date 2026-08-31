require "test_helper"

class QrLoginTest < ActiveSupport::TestCase
  setup { Option.delete_all }

  # ── 注册表 ────────────────────────────────────────────

  test "find returns the provider class and raises on unknown keys" do
    assert_equal QrLogin::Weread, QrLogin.find("weread")
    assert_equal QrLogin::WechatMp, QrLogin.find(:wechat_mp)
    assert_raises(QrLogin::Error) { QrLogin.find("nope") }
  end

  test "card actions map back to providers" do
    # 旧卡片已经发到飞书会话里了，action 值必须保持 "weread_login"
    assert_equal "weread_login", QrLogin::Weread.card_action
    assert_equal QrLogin::Weread, QrLogin.find_by_card_action("weread_login")
    assert_equal QrLogin::WechatMp, QrLogin.find_by_card_action("wechat_mp_login")
    assert_nil QrLogin.find_by_card_action("something_else")
    assert_nil QrLogin.find_by_card_action(nil)
  end

  # ── WeRead ───────────────────────────────────────────

  test "weread start renders the QR locally and keeps the uuid in the handle" do
    create_login_url = -> { { "uuid" => "uuid-1", "scanUrl" => "https://weread.example/scan/abc" } }

    stub_class_method(WereadApiClient, :create_login_url, create_login_url) do
      result = QrLogin::Weread.start

      assert_equal "uuid-1", result[:handle]["uuid"]
      assert_equal "image/png", result[:image_mime]
      assert result[:image_bytes].b.start_with?("\x89PNG".b), "二维码应在服务端本地渲染成 PNG"
    end
  end

  test "weread start fails loudly when the relay returns no QR" do
    stub_class_method(WereadApiClient, :create_login_url, -> { { "uuid" => nil, "scanUrl" => nil } }) do
      assert_raises(QrLogin::Error) { QrLogin::Weread.start }
    end
  end

  test "weread poll normalizes free-form messages into statuses" do
    {
      "等待扫码" => :waiting,
      "已扫码，请在手机确认" => :scanned,
      "二维码已过期" => :expired
    }.each do |message, expected|
      poll = proc { |*, **| { "message" => message } }

      stub_class_method(WereadApiClient, :get_login_result, poll) do
        assert_equal expected, QrLogin::Weread.poll({ "uuid" => "u" })[:status], "message=#{message}"
      end
    end
  end

  test "weread poll treats a login status timeout as temporary waiting" do
    timeout = proc { |*, **| raise WereadApiClient::LoginPollTimeoutError, "检查登录状态超时: execution expired" }

    stub_class_method(WereadApiClient, :get_login_result, timeout) do
      result = QrLogin::Weread.poll({ "uuid" => "u" })

      assert_equal :waiting, result[:status]
      assert_match "暂时超时", result[:message]
    end
  end

  test "weread poll surfaces non-timeout relay errors instead of raising" do
    boom = proc { |*, **| raise WereadApiClient::ApiError, "检查登录状态失败: timeout" }

    stub_class_method(WereadApiClient, :get_login_result, boom) do
      result = QrLogin::Weread.poll({ "uuid" => "u" })

      assert_equal :error, result[:status]
      assert_match "timeout", result[:message]
    end
  end

  test "weread poll reports success once vid and token arrive" do
    payload = { "vid" => "v1", "token" => "t1", "username" => "读书人" }

    stub_class_method(WereadApiClient, :get_login_result, proc { |*, **| payload }) do
      result = QrLogin::Weread.poll({ "uuid" => "u" })

      assert_equal :success, result[:status]
      assert_equal payload, result[:result]
    end

    assert_equal "读书人", QrLogin::Weread.save_success!(payload)
    assert_equal 1, Option.weread_accounts.size
    assert_equal "v1", Option.weread_accounts.first["vid"]
  end

  test "weread reminder is unconditional so the account pool keeps growing" do
    assert QrLogin::Weread.reminder_needed?
  end

  # ── 微信公众号平台 ────────────────────────────────────

  test "wechat_mp start carries the cookie jar in the handle" do
    qr = -> { { uuid: "mp-uuid", cookie_jar: { "slave_sid" => "abc" }, image_bytes: "PNGDATA", image_ext: "png" } }

    stub_class_method(WechatMpNativeApiClient, :request_qr_code, qr) do
      result = QrLogin::WechatMp.start

      assert_equal "mp-uuid", result[:handle]["uuid"]
      assert_equal({ "slave_sid" => "abc" }, result[:handle]["cookie_jar"])
      assert_equal "image/png", result[:image_mime]
    end
  end

  test "wechat_mp poll round-trips the refreshed cookie jar" do
    check = proc do |_uuid, _jar|
      { status: "scanned", message: "已扫码", cookie_jar: { "slave_sid" => "new" } }
    end

    stub_class_method(WechatMpNativeApiClient, :check_qr_status, check) do
      result = QrLogin::WechatMp.poll({ "uuid" => "u", "cookie_jar" => { "slave_sid" => "old" } })

      assert_equal :scanned, result[:status]
      assert_equal({ "slave_sid" => "new" }, result[:handle]["cookie_jar"],
                   "轮询带回的新 cookie 必须回存，否则后续步骤会丢会话")
      assert_nil result[:result]
    end
  end

  test "wechat_mp save_success! persists through Option and returns the account name" do
    payload = { status: :success, cookie_str: "c=1", token: "tok", account_info: { nickname: "某公众号" } }

    freeze_time do
      assert_equal "某公众号", QrLogin::WechatMp.save_success!(payload)
      assert_equal "c=1", Option.wechat_mp_cookie
      assert_equal "tok", Option.wechat_mp_token
      assert_equal (Time.current + Option::WECHAT_MP_SESSION_TTL).iso8601, Option.wechat_mp_expires_at
    end
  end

  test "wechat_mp reminder follows the live session probe, not the stored timestamp" do
    Option.wechat_api_provider = "mp_native"

    stub_class_method(WechatMpNativeApiClient, :validate_session, -> { false }) do
      assert QrLogin::WechatMp.reminder_needed?
    end

    stub_class_method(WechatMpNativeApiClient, :validate_session, -> { true }) do
      assert_not QrLogin::WechatMp.reminder_needed?
    end
  end

  test "wechat_mp stays quiet when another provider is active and it was never logged in" do
    Option.wechat_api_provider = "weread"

    stub_class_method(WechatMpNativeApiClient, :validate_session, -> { false }) do
      assert_not QrLogin::WechatMp.reminder_needed?

      # 一旦登录过（cookie 还在），失效就要提醒——帐号搜索仍依赖这个会话
      Option.wechat_mp_cookie = "c=1"
      assert QrLogin::WechatMp.reminder_needed?
    end
  end
end
