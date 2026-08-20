module Oauth
  class TokenController < ApplicationController
    skip_before_action :verify_authenticity_token

    # POST /oauth/token
    # Token endpoint - supports device_code grant type
    def create
      grant_type = params[:grant_type]

      case grant_type
      when "urn:ietf:params:oauth:grant-type:device_code"
        handle_device_code_grant
      else
        render json: {
          error: "unsupported_grant_type",
          error_description: "Grant type '#{grant_type}' is not supported"
        }, status: :bad_request
      end
    end

    private

    def handle_device_code_grant
      device_code_value = params[:device_code]
      client_id = params[:client_id]

      if device_code_value.blank?
        render_token_error("invalid_request", "device_code is required")
        return
      end

      device_code = DeviceCode.find_by(device_code: device_code_value)

      if device_code.nil?
        render_token_error("invalid_grant", "Invalid device code")
        return
      end

      if device_code.expired?
        device_code.mark_expired!
        render_token_error("expired_token", "Device code has expired")
        return
      end

      case device_code.status
      when "pending"
        render_token_error("authorization_pending", "User has not yet authorized")
      when "denied"
        render_token_error("access_denied", "User denied the authorization request")
      when "authorized"
        # Generate an API key for the authorized user
        api_key = ApiKey.create!(
          user: device_code.user,
          name: "MCP Client (#{device_code.client_id})"
        )

        # Mark device code as consumed (we don't have a "consumed" status, but we can expire it)
        device_code.update!(status: :expired)

        render json: {
          access_token: api_key.token,
          token_type: "Bearer",
          expires_in: nil,  # API keys don't expire
          scope: device_code.scope
        }
      end
    end

    def render_token_error(error, description)
      render json: {
        error: error,
        error_description: description
      }, status: :bad_request
    end
  end
end
