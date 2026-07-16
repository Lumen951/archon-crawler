class ProfilesController < ApplicationController
  def edit
    @user = current_user
    @api_keys = @user.api_keys.order(created_at: :desc)
  end

  def update
    @user = current_user

    if @user.update(user_params)
      flash[:success] = "个人信息已更新"
      redirect_to edit_profile_path
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def create_api_key
    name = params[:api_key_name].to_s.strip.presence || "Default"
    api_key = current_user.api_keys.build(name: name)

    if api_key.save
      flash[:api_key_token] = api_key.token
      flash[:success] = "API Key \"#{name}\" 已生成，请复制保存"
    else
      flash[:error] = "生成失败：#{api_key.errors.full_messages.join(', ')}"
    end

    redirect_to edit_profile_path
  end

  def revoke_api_key
    api_key = current_user.api_keys.find(params[:api_key_id])
    api_key.update!(active: false)
    flash[:success] = "API Key \"#{api_key.name}\" 已撤销"
  rescue ActiveRecord::RecordNotFound
    flash[:error] = "未找到该 API Key"
  ensure
    redirect_to edit_profile_path
  end

  def update_password
    @user = current_user

    unless @user.authenticate(params[:current_password])
      flash[:error] = "当前密码不正确"
      redirect_to edit_profile_path and return
    end

    if params[:new_password].blank?
      flash[:error] = "新密码不能为空"
      redirect_to edit_profile_path and return
    end

    if params[:new_password] != params[:password_confirmation]
      flash[:error] = "两次输入的密码不一致"
      redirect_to edit_profile_path and return
    end

    if @user.update(password: params[:new_password])
      flash[:success] = "密码已成功更新"
      redirect_to edit_profile_path
    else
      flash[:error] = "密码更新失败：#{@user.errors.full_messages.join(', ')}"
      redirect_to edit_profile_path
    end
  end

  private

  def user_params
    params.require(:user).permit(:email_address, :name, settings: [:notify_api_key_expiry])
  end
end
