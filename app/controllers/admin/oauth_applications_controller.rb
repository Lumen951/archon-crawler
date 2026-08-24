module Admin
  # Manages the OAuth 2.1 clients that have connected to the MCP endpoint.
  # Clients registered dynamically via /oauth/register land in Doorkeeper's
  # oauth_applications table; destroying one revokes it and, via Doorkeeper's
  # `dependent: :delete_all`, removes every access token and grant it was issued.
  class OauthApplicationsController < Admin::BaseController
    def index
      @applications = Doorkeeper::Application.order(created_at: :desc)
    end

    def destroy
      application = Doorkeeper::Application.find(params[:id])
      application.destroy!
      flash[:success] = "已撤销客户端 #{application.name} 及其所有令牌"
      redirect_to admin_oauth_applications_path
    end
  end
end
