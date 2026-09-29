require "test_helper"

# == Schema Information
#
# Table name: options
#
#  id         :bigint           not null, primary key
#  opt_key    :string           not null
#  opt_value  :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_options_on_opt_key  (opt_key) UNIQUE
#
class OptionTest < ActiveSupport::TestCase
  setup { Option.delete_all }

  test "wechat_mp_session_started! writes the whole session with a TTL-derived expiry" do
    freeze_time do
      Option.wechat_mp_session_started!(cookie: "c=1; d=2", token: "tok123", account_info: { nickname: "测试号" })

      assert_equal "c=1; d=2", Option.wechat_mp_cookie
      assert_equal "tok123", Option.wechat_mp_token
      assert_equal "success", Option.wechat_mp_login_state
      assert_equal "测试号", JSON.parse(Option.wechat_mp_account_info)["nickname"]
      assert_equal (Time.current + Option::WECHAT_MP_SESSION_TTL).iso8601, Option.wechat_mp_expires_at
      assert Option.wechat_mp_session_valid?
    end
  end

  test "session is invalid once expires_at is in the past" do
    Option.wechat_mp_session_started!(cookie: "c=1", token: "tok")
    Option.wechat_mp_expires_at = 1.minute.ago.iso8601

    assert_not Option.wechat_mp_session_valid?
  end

  test "wechat_mp_session_cleared! wipes every session key" do
    Option.wechat_mp_session_started!(cookie: "c=1", token: "tok")
    Option.wechat_mp_session_cleared!

    assert_nil Option.wechat_mp_cookie
    assert_nil Option.wechat_mp_token
    assert_nil Option.wechat_mp_expires_at
    assert_nil Option.wechat_mp_login_state
    assert_not Option.wechat_mp_session_valid?
  end

  test "ttl label is derived from the constant" do
    assert_equal "约 4 天", Option.wechat_mp_session_ttl_label
  end

  test "feishu_login_mode falls back to the legacy weread key" do
    assert_equal "qr", Option.feishu_login_mode

    Option.set("feishu_weread_login_mode", "card")
    assert_equal "card", Option.feishu_login_mode
    assert Option.feishu_login_card_mode?

    # 新 key 优先于旧 key
    Option.feishu_login_mode = "qr"
    assert_equal "qr", Option.feishu_login_mode
    assert_not Option.feishu_login_card_mode?
  end

  # ── 小红书网页版 Cookie 会话（远程浏览器登录写入）──────

  test "rednote_web_session_started! writes the whole session and reports valid" do
    Option.rednote_web_session_started!(cookie: "web_session=abc", account_info: { "nickname" => "某人" })

    assert_equal "web_session=abc", Option.rednote_web_cookie
    assert_equal "success", Option.rednote_web_login_state
    assert Option.rednote_web_expires_at.present?
    assert Option.rednote_web_session_valid?
    assert_equal "某人", JSON.parse(Option.rednote_web_account_info)["nickname"]
  end

  test "rednote_web_session_cleared! wipes every session key" do
    Option.rednote_web_session_started!(cookie: "web_session=abc")
    Option.rednote_web_session_cleared!

    assert_nil Option.rednote_web_cookie
    assert_nil Option.rednote_web_expires_at
    assert_nil Option.rednote_web_login_state
    assert_not Option.rednote_web_session_valid?
  end

  test "rednote_web_session_valid? expires with the stored timestamp" do
    Option.rednote_web_cookie = "web_session=abc"
    Option.rednote_web_expires_at = 1.minute.ago.iso8601

    assert_not Option.rednote_web_session_valid?
  end

  test "browser_login_headed flag round-trips" do
    assert_not Option.browser_login_headed?

    Option.browser_login_headed = "1"
    assert Option.browser_login_headed?

    Option.browser_login_headed = false
    assert_not Option.browser_login_headed?
  end

  test "browser_login_proxy round-trips and blanks out" do
    assert_nil Option.browser_login_proxy

    Option.browser_login_proxy = "http://127.0.0.1:7890"
    assert_equal "http://127.0.0.1:7890", Option.browser_login_proxy

    Option.browser_login_proxy = ""
    assert_nil Option.browser_login_proxy, "空字符串应按未配置处理"
  end

  test "wechat content browser fallback is enabled by default and can be disabled" do
    assert Option.wechat_content_browser_fallback_enabled?

    Option.set("wechat_content_browser_fallback", "false")
    assert_not Option.wechat_content_browser_fallback_enabled?
  end
end
