module Oauth
  # Doorkeeper owns /oauth/token now, but the RFC 8628 device flow used the same
  # endpoint before Doorkeeper existed here and is documented in docs/mcp.md, so
  # that grant type keeps working alongside authorization_code and refresh_token.
  class TokensController < Doorkeeper::TokensController
    DEVICE_CODE_GRANT = "urn:ietf:params:oauth:grant-type:device_code".freeze

    def create
      return handle_device_code_grant if params[:grant_type] == DEVICE_CODE_GRANT

      super
    end

    private

    def handle_device_code_grant
      device_code_value = params[:device_code]

      if device_code_value.blank?
        return render_token_error("invalid_request", "device_code is required")
      end

      device_code = DeviceCode.find_by(device_code: device_code_value)

      if device_code.nil?
        return render_token_error("invalid_grant", "Invalid device code")
      end

      if device_code.expired?
        device_code.mark_expired!
        return render_token_error("expired_token", "Device code has expired")
      end

      case device_code.status
      when "pending"
        render_token_error("authorization_pending", "User has not yet authorized")
      when "denied"
        render_token_error("access_denied", "User denied the authorization request")
      when "authorized"
        issue_api_key_for(device_code)
      end
    end

    # The device flow predates Doorkeeper here and still hands out a long-lived
    # ApiKey rather than an OAuth access token; McpController accepts both.
    def issue_api_key_for(device_code)
      api_key = ApiKey.create!(
        user: device_code.user,
        name: "MCP Client (#{device_code.client_id})"
      )

      device_code.update!(status: :expired)

      render json: {
        access_token: api_key.token,
        token_type: "Bearer",
        expires_in: nil,
        scope: device_code.scope
      }
    end

    def render_token_error(error, description)
      render json: { error: error, error_description: description }, status: :bad_request
    end
  end
end
