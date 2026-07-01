module Authorization
  extend ActiveSupport::Concern

  included do
    rescue_from NotAuthorizedError, with: :handle_unauthorized
    helper_method :current_user_is_admin?
  end

  class NotAuthorizedError < StandardError; end

  def require_admin
    unless current_user&.admin?
      raise NotAuthorizedError, "您没有权限访问此页面"
    end
  end

  alias_method :authorize_admin!, :require_admin

  def current_user_is_admin?
    current_user&.admin?
  end

  private

  def handle_unauthorized(exception)
    redirect_to root_path, alert: exception.message
  end
end
