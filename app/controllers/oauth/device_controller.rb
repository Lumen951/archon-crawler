module Oauth
  class DeviceController < ApplicationController
    # A headless client calls #create with no session at all — it is asking for
    # a code that the user will approve in a browser afterwards. #show and
    # #authorize are the browser half and keep ApplicationController's usual
    # `require_authentication` gate.
    allow_unauthenticated_access only: [ :create ]
    skip_before_action :verify_authenticity_token, only: [ :create ]
    layout "oauth"

    # POST /oauth/device
    # Request a device code (called by MCP client)
    def create
      client_id = params[:client_id]
      scope = params[:scope]

      if client_id.blank?
        render json: { error: "client_id is required" }, status: :bad_request
        return
      end

      device_code = DeviceCode.create!(
        client_id: client_id,
        scope: scope
      )

      render json: {
        device_code: device_code.device_code,
        user_code: device_code.user_code,
        verification_uri: oauth_device_authorize_url,
        verification_uri_complete: "#{oauth_device_authorize_url}?code=#{device_code.user_code}",
        expires_in: 900,
        interval: 5
      }, status: :ok
    end

    # GET /oauth/device/authorize
    # Show authorization page (user visits this in browser)
    def show
      @user_code = params[:code]
      @device_code = nil

      if @user_code.present?
        @device_code = DeviceCode.active.find_by(user_code: @user_code.upcase)
      end
    end

    # POST /oauth/device/authorize
    # User submits authorization (approve/deny)
    def authorize
      user_code = params[:code]&.upcase
      action = params[:action_type]

      device_code = DeviceCode.active.find_by(user_code: user_code)

      if device_code.nil?
        flash[:error] = "授权码无效或已过期"
        redirect_to oauth_device_authorize_path(code: user_code)
        return
      end

      case action
      when "approve"
        device_code.authorize!(current_user)
        flash[:notice] = "授权成功！请返回终端继续操作。"
      when "deny"
        device_code.deny!
        flash[:error] = "已拒绝授权。"
      end

      redirect_to oauth_device_authorize_path(code: user_code)
    end
  end
end
