require "test_helper"

class RegistrationFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @password = "a-long-test-password"
    @rate_store = RegistrationsController.cache_store
    @original_increment = @rate_store.method(:increment)
    memory = ActiveSupport::Cache::MemoryStore.new
    @rate_store.define_singleton_method(:increment) { |*args, **options| memory.increment(*args, **options) }
  end

  teardown do
    @rate_store.define_singleton_method(:increment, @original_increment)
  end

  test "registers without mail and allows password login without claiming verification" do
    assert_difference "User.count", 1 do
      assert_no_enqueued_emails do
        register(" New.Person@ARCHON.TECH ", role: "admin", email_confirmed_at: Time.current,
          settings: { mailbox_verified: true })
      end
    end
    assert_redirected_to new_session_path
    user = User.find_by!(email_address: "new.person@archon.tech")
    assert user.user?
    refute user.email_confirmed?
    refute user.enterprise_email_verified?
    post session_path, params: { email_address: user.email_address, password: @password }
    assert_redirected_to root_path
    get edit_profile_path
    assert_match "未验证邮箱归属", response.body
    assert_nil user.reload.email_confirmed_at
  end

  test "previously pending enterprise users can login with their existing password" do
    user = pending_user
    post session_path, params: { email_address: user.email_address, password: @password }
    assert_redirected_to root_path
    refute user.reload.email_confirmed?
  end

  test "rejects nonenterprise and misleading domains and weak passwords" do
    %w[person@example.test person@archon.tech.example.test person@fakearchon.tech person@sub.archon.tech].each do |email|
      assert_no_difference "User.count" do
        register(email)
      end
      assert_response :unprocessable_entity
    end
    register("weak@archon.tech", password: "short", password_confirmation: "short")
    assert_response :unprocessable_entity
    register("different@archon.tech", password_confirmation: "different")
    assert_response :unprocessable_entity
  end

  test "duplicate registration cannot replace password or permissions" do
    user = pending_user
    digest = user.password_digest
    assert_no_difference "User.count" do
      assert_no_enqueued_emails do
        register(user.email_address, password: "attacker-password", password_confirmation: "attacker-password")
      end
    end
    assert_redirected_to new_session_path
    assert_equal digest, user.reload.password_digest
  end

  test "registration limits repeated requests across IP addresses" do
    register("cooldown@archon.tech")
    post registration_path, params: { user: { email_address: " COOLDOWN@ARCHON.TECH " } },
      env: { "REMOTE_ADDR" => "192.0.2.44" }
    assert_response :too_many_requests
  end

  test "IP limit applies across different email addresses" do
    10.times do |index|
      register("missing#{index}@example.test")
    end
    register("another@example.test")
    assert_response :too_many_requests
  end

  test "profile requests cannot change email or verification evidence" do
    user = pending_user
    user.confirm_email!
    post session_path, params: { email_address: user.email_address, password: @password }
    patch profile_path, params: { user: { email_address: "changed@archon.tech" } }
    assert_redirected_to edit_profile_path
    assert_equal "person@archon.tech", user.reload.email_address
    patch profile_path, params: { user: { name: "Updated", settings: { mailbox_verified: true } } }
    refute user.reload.enterprise_email_verified?
    refute user.update(email_address: "changed@archon.tech")
  end

  test "profile preferences preserve verified mailbox evidence" do
    user = pending_user
    user.update!(email_confirmed_at: Time.current, settings: { mailbox_verified: true })
    post session_path, params: { email_address: user.email_address, password: @password }
    patch profile_path, params: { user: { settings: { notify_api_key_expiry: "1", mailbox_verified: false } } }
    assert user.reload.enterprise_email_verified?
  end

  test "renders registration without email verification entry points" do
    get new_session_path
    assert_select "a[href=?]", new_registration_path
    get new_registration_path
    assert_response :success
    assert_select "input[name='user[password_confirmation]']"
    assert_select "input[type=submit][value='注册账号']"
  end

  private

  def register(email, extra = {})
    post registration_path, params: { user: {
      email_address: email, name: "Test", password: @password, password_confirmation: @password
    }.merge(extra) }
  end

  def pending_user
    User.create!(email_address: "person@archon.tech", password: @password)
  end
end
