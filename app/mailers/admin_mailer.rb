class AdminMailer < ApplicationMailer
  def invitation(user, magic_link_url)
    @user = user
    @magic_link_url = magic_link_url

    mail(
      to: user.email_address,
      subject: "欢迎登录 MP-Crawler"
    )
  end

  def magic_login_link(user, magic_link_url)
    @user = user
    @magic_link_url = magic_link_url

    mail(
      to: user.email_address,
      subject: "您的 MP-Crawler 登录链接"
    )
  end

  def new_user_credentials(user, password)
    @user = user
    @password = password

    mail(
      to: user.email_address,
      subject: "您的 MP-Crawler 账户登录信息"
    )
  end
end
