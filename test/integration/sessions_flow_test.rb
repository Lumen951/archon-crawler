require "test_helper"

class SessionsFlowTest < ActionDispatch::IntegrationTest
  setup do
    ActionMailer::Base.deliveries.clear

    @confirmed_user = User.create!(
      email_address: "confirmed@example.com",
      password: "password123",
      password_confirmation: "password123",
      email_confirmed_at: Time.current
    )

    @unconfirmed_user = User.create!(
      email_address: "pending@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  test "renders password and magic-link login options" do
    get new_session_path

    assert_response :success
    assert_match "发送魔法登录链接", response.body
    assert_match "15 分钟内有效的登录链接", response.body
  end

  test "sends magic link for confirmed user with neutral message" do
    assert_enqueued_emails 1 do
      post magic_link_session_path, params: { email_address: @confirmed_user.email_address }
    end

    assert_redirected_to new_session_path
    follow_redirect!
    assert_match SessionsController::MAGIC_LINK_REQUEST_NOTICE, response.body
  end

  test "does not send magic link for unknown email and keeps neutral message" do
    assert_enqueued_emails 0 do
      post magic_link_session_path, params: { email_address: "missing@example.com" }
    end

    assert_redirected_to new_session_path
    follow_redirect!
    assert_match SessionsController::MAGIC_LINK_REQUEST_NOTICE, response.body
  end

  test "does not send magic link for unconfirmed user and keeps neutral message" do
    assert_enqueued_emails 0 do
      post magic_link_session_path, params: { email_address: @unconfirmed_user.email_address }
    end

    assert_redirected_to new_session_path
    follow_redirect!
    assert_match SessionsController::MAGIC_LINK_REQUEST_NOTICE, response.body
  end

  test "password login returns to the requested event research run" do
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:login-return")
    run = EventResearchRun.create!(account: account, status: :completed, completed_at: Time.current)
    destination = event_account_path(account, run_id: run.id)

    get destination

    assert_redirected_to new_session_path

    post session_path, params: { email_address: @confirmed_user.email_address, password: "password123" }

    assert_redirected_to destination
  end

  test "magic link logs in confirmed user" do
    get magic_link_path(@confirmed_user.generate_magic_link_token)

    assert_redirected_to root_path
    follow_redirect!
    assert_match "登录成功！", response.body
  end

  test "magic link rejects invalid token" do
    get magic_link_path("invalid-token")

    assert_redirected_to new_session_path
    follow_redirect!
    assert_match "登录链接无效或已过期", response.body
  end

  test "magic link rejects unconfirmed user token" do
    get magic_link_path(@unconfirmed_user.generate_magic_link_token)

    assert_redirected_to new_session_path
    follow_redirect!
    assert_match "登录链接无效或已过期", response.body
  end
end
