class RegistrationsController < ApplicationController
  NOTICE = "该邮箱已有账号，请直接登录或联系管理员。".freeze

  allow_unauthenticated_access
  rate_limit to: 10, within: 10.minutes, only: :create, name: "registration_ip",
    with: -> { render plain: "操作过于频繁，请十分钟后重试。", status: :too_many_requests }
  rate_limit to: 1, within: 1.minute, only: :create, name: "registration_email",
    by: -> { Digest::SHA256.hexdigest(registration_email) },
    with: -> { render plain: "请等待一分钟后重试。", status: :too_many_requests }

  def new
    @user = User.new
    render "sessions/register"
  end

  def create
    @user = User.new(params.require(:user).permit(:name, :email_address, :password, :password_confirmation))
    @user.role = :user
    if User.exists?(email_address: registration_email)
      redirect_to new_session_path, notice: NOTICE
    elsif @user.save(context: :registration)
      redirect_to new_session_path, notice: "注册成功，请使用邮箱和密码登录。"
    else
      render "sessions/register", status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    redirect_to new_session_path, notice: NOTICE
  end

  private

  def registration_email
    (params.dig(:user, :email_address) || params[:email_address]).to_s.strip.downcase
  end
end
