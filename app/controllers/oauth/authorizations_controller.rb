module Oauth
  # Doorkeeper's authorization endpoint, with the resource-indicator check the
  # MCP spec requires bolted on. ApplicationController's `require_authentication`
  # has already run by the time we get here, so the user is signed in.
  class AuthorizationsController < Doorkeeper::AuthorizationsController
    layout "oauth"
    before_action :validate_resource_parameter

    private

    # RFC 8707: an authorization server must not mint a token for a resource it
    # does not serve. We serve exactly one — the MCP endpoint. A missing
    # `resource` is tolerated (older clients omit it); a wrong one is refused.
    def validate_resource_parameter
      requested = params[:resource]
      return if requested.blank?
      return if McpOauth.matches_resource?(requested, request.base_url)

      render json: {
        error: "invalid_target",
        error_description: "This authorization server does not issue tokens for #{requested}"
      }, status: :bad_request
    end
  end
end
