class SessionsController < ApplicationController
  MAGIC_LINK_REQUEST_NOTICE = "如果该邮箱可用，我们已发送登录链接，请检查收件箱。".freeze

  allow_unauthenticated_access only: %i[ new create magic_link magic_link_login dev_login ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." }
  rate_limit to: 5, within: 10.minutes, only: :magic_link, with: -> { redirect_to new_session_path, notice: MAGIC_LINK_REQUEST_NOTICE }

  def new
  end

  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      unless user.email_confirmed?
        redirect_to new_session_path, alert: "请先验证您的邮箱，检查您的收件箱。"
        return
      end

      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: "邮箱或密码错误，请重试。"
    end
  end

  def magic_link
    user = User.find_by(email_address: params[:email_address].to_s.strip.downcase)

    if user&.email_confirmed?
      token = user.generate_magic_link_token
      AdminMailer.magic_login_link(user, magic_link_url(token)).deliver_later
    end

    redirect_to new_session_path, notice: MAGIC_LINK_REQUEST_NOTICE
  end

  def magic_link_login
    user = User.find_by_magic_link_token(params[:token])

    if user&.email_confirmed?
      start_new_session_for(user)
      redirect_to after_authentication_url, notice: "登录成功！"
    else
      redirect_to new_session_path, alert: "登录链接无效或已过期"
    end
  end

  def dev_login
    unless Rails.env.development? || Rails.env.test?
      redirect_to new_session_path, alert: "此功能仅在开发环境可用"
      return
    end

    user = User.developer_account!

    start_new_session_for(user)
    redirect_to after_authentication_url, notice: "已以开发者身份登录"
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
