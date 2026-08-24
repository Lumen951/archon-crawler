require "test_helper"

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
end
