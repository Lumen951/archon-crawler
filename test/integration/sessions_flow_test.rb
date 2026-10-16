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
    assert_select "html[lang='zh-CN']"
    assert_select "title", "登录源策未来 · ARCHON"
    assert_select "h2", "登录源策未来"
    assert_select "form#password-login[action=?]", session_path do
      assert_select "input#password-email[name='email_address'][autocomplete='username']"
      assert_select "label[for='password-email']", "邮箱地址"
      assert_select "input#login-password[name='password'][autocomplete='current-password']"
      assert_select "input[type='submit'][value='进入工作台']"
    end
    assert_select "details.auth-email-link" do
      assert_select "form#email-link-login[action=?]", magic_link_session_path do
        assert_select "input#magic-link-email[name='email_address']"
        assert_select "label[for='magic-link-email']", "邮箱地址"
        assert_select "input[type='submit'][value='发送登录链接']"
      end
    end
    assert_select "a[href='/auth/mp']", count: 0
    assert_no_match(/MiraclePlus/, response.body)
    assert_select "button", text: "以 Archon Developer 身份进入"
    ids = css_select("[id]").map { |element| element["id"] }
    assert_equal ids.uniq, ids, "Login page must not contain duplicate element IDs"
    assert_match "15 分钟内有效的登录链接", response.body
  end

  test "signed-in navigation uses Archon labels and existing routes" do
    post session_path, params: { email_address: @confirmed_user.email_address, password: "password123" }
    follow_redirect!

    assert_response :success
    assert_select "a.archon-brand", text: /源策未来/
    assert_select "nav[aria-label='主导航']" do
      assert_select "a[href=?]", accounts_path, text: /内容源/
      assert_select "a[href=?]", articles_path, text: /内容库/
      assert_select "a[href=?]", crawl_tasks_path, text: /采集任务/
    end
  end

  test "developer login creates a named admin and reuses the account" do
    User.find_by(email_address: "developer@archon.test")&.destroy!

    assert_difference "User.count", 1 do
      post dev_login_session_path
    end
    assert_redirected_to root_path
    developer = User.find_by!(email_address: "developer@archon.test")
    assert_equal "Archon Developer", developer.name
    assert developer.admin?
    assert developer.email_confirmed?
    assert_not developer.authenticate("password123")
    assert_not developer.authenticate("12345678")
    digest = developer.password_digest
    assert_equal developer.id, Session.order(:id).last.user_id

    delete session_path
    assert_no_difference "User.count" do
      post dev_login_session_path
    end
    assert_equal digest, developer.reload.password_digest
  end

  test "developer login and account creation reject production" do
    stub_class_method(Rails, :env, -> { ActiveSupport::EnvironmentInquirer.new("production") }) do
      assert_no_difference ["User.count", "Session.count"] do
        post dev_login_session_path
      end
      assert_redirected_to new_session_path
      assert_raises(RuntimeError) { User.developer_account! }
      get new_session_path
      assert_select "form[action=?]", dev_login_session_path, count: 0
    end
  end

  test "legacy SSO routes are removed" do
    ["/auth/mp", "/oauth/mp/callback"].each do |path|
      assert_raises(ActionController::RoutingError) do
        Rails.application.routes.recognize_path(path, method: :get)
      end
    end
  end

  test "seeding is repeatable and never creates the former personal admin" do
    2.times { load Rails.root.join("db/seeds.rb") }
    assert_equal 1, User.where(email_address: "developer@archon.test").count
    assert_not User.exists?(email_address: "shaokun.wu@gmail.com")
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
