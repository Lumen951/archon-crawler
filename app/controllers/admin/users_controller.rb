class Admin::UsersController < Admin::BaseController
  before_action :set_user, only: [:show, :edit, :update, :destroy, :reset_password]

  def index
    @users = User.includes(:followed_tags).order(created_at: :desc)
    @tags = Tag.ordered
  end

  def show
    @sessions = @user.sessions.order(created_at: :desc).limit(20)
  end

  def new
    @user = User.new
  end

  def create
    @user = User.new(user_params)
    notification_method = params[:notification_method]

    # Generate password if not provided
    if @user.password.blank?
      generated_password = User.generate_random_password
      @user.password = generated_password
      @user.password_confirmation = generated_password
    else
      generated_password = @user.password
    end

    @user.email_confirmed_at = Time.current

    if @user.save
      case notification_method
      when "magic_link"
        # Send invitation email with magic link (7 day expiration)
        token = @user.generate_magic_link_token(expires_in: 7.days)
        magic_link_url = magic_link_url(token)
        AdminMailer.invitation(@user, magic_link_url).deliver_later
        redirect_to admin_users_path, notice: "用户创建成功，邀请邮件已发送"
      when "generated_password"
        # Send email with auto-generated password
        AdminMailer.new_user_credentials(@user, generated_password).deliver_later
        redirect_to admin_users_path, notice: "用户创建成功，登录凭证已发送"
      when "manual"
        # Store password in encrypted flash for one-time display
        flash[:user_credentials] = {
          user_id: @user.id,
          email: @user.email_address,
          password: generated_password
        }
        redirect_to admin_user_credentials_path(@user)
      else
        redirect_to admin_users_path, notice: "用户创建成功"
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    # Handle password update
    if user_update_params[:password].present?
      if @user.update(user_update_params)
        redirect_to admin_user_path(@user), notice: "用户更新成功"
      else
        render :edit, status: :unprocessable_entity
      end
    else
      # Update without password
      if @user.update(user_update_params.except(:password, :password_confirmation))
        redirect_to admin_user_path(@user), notice: "用户更新成功"
      else
        render :edit, status: :unprocessable_entity
      end
    end
  end

  def destroy
    if @user == current_user
      redirect_to admin_users_path, alert: "不能删除自己的账户"
      return
    end

    @user.destroy
    redirect_to admin_users_path, notice: "用户已删除"
  end

  def show_credentials
    credentials = flash[:user_credentials]

    if credentials.blank?
      redirect_to admin_users_path, alert: "凭证已过期或不存在"
      return
    end

    @user = User.find(credentials["user_id"])
    @generated_password = credentials["password"]
  end

  def reset_password
    # Generate new password
    generated_password = User.generate_random_password
    @user.password = generated_password
    @user.password_confirmation = generated_password

    if @user.save
      # Store password in encrypted flash for one-time display
      flash[:user_credentials] = {
        user_id: @user.id,
        email: @user.email_address,
        password: generated_password
      }
      redirect_to admin_user_credentials_path(@user)
    else
      redirect_back fallback_location: admin_users_path, alert: "密码重置失败"
    end
  end

  def update_followed_tags
    tag_ids = (params[:tag_ids] || []).map(&:to_i)
    @user.user_tags.where.not(tag_id: tag_ids).destroy_all
    tag_ids.each { |tid| @user.user_tags.find_or_create_by(tag_id: tid) }
    flash[:success] = "已更新 #{@user.name || @user.email_address} 的关注标签"
    redirect_to admin_users_path
  end

  private

  def set_user
    @user = User.find(params[:id])
  end

  def user_params
    params.require(:user).permit(:email_address, :password, :password_confirmation, :role, :name)
  end

  def user_update_params
    params.require(:user).permit(:email_address, :password, :password_confirmation, :role, :name)
  end
end
