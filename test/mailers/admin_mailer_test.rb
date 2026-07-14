require "test_helper"

class AdminMailerTest < ActionMailer::TestCase
  test "magic_login_link renders recipient, subject, and link" do
    user = User.create!(
      email_address: "mailer@example.com",
      password: "password123",
      password_confirmation: "password123",
      email_confirmed_at: Time.current
    )
    link = "http://example.com/magic_link/token123"

    email = AdminMailer.magic_login_link(user, link)

    assert_equal [user.email_address], email.to
    assert_equal "您的 MP-Crawler 登录链接", email.subject
    assert_includes email.html_part.body.to_s, link
    assert_includes email.text_part.body.to_s, link
    assert_includes email.html_part.body.to_s, "15 分钟后过期"
    assert_includes email.text_part.body.to_s, "15 分钟后过期"
  end
end
