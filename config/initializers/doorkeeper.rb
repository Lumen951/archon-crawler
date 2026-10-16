# OAuth 2.1 authorization server for MCP clients (Claude Code, Codex, ...).
#
# See app/services/mcp_oauth.rb for the resource-server side. Scope strings are
# duplicated here as literals because an initializer must not reference an
# autoloaded constant at boot; test/services/mcp_oauth_test.rb asserts the two
# definitions stay in sync.
Doorkeeper.configure do
  orm :active_record

  # Running the authorization endpoint on ApplicationController means anonymous
  # visitors hit the app's normal `require_authentication` gate first, which
  # bounces them through password / magic link login and returns them here.
  base_controller "ApplicationController"

  resource_owner_authenticator do
    current_user || begin
      session[:return_to_after_authenticating] = request.fullpath
      redirect_to(new_session_path)
      nil
    end
  end

  admin_authenticator do
    current_user&.admin? || redirect_to(root_path)
  end

  # MCP clients are public native clients: they register themselves through
  # Dynamic Client Registration, hold no secret, and prove possession with PKCE.
  grant_flows %w[authorization_code]
  use_refresh_token
  force_pkce
  pkce_code_challenge_methods %w[S256]

  # Short-lived access tokens plus rotation is the whole point of moving MCP off
  # never-expiring API keys — a leaked token stops working in two hours.
  access_token_expires_in 2.hours
  authorization_code_expires_in 10.minutes

  default_scopes  "mcp:read"
  optional_scopes "mcp:write"
  enforce_configured_scopes

  # Stored as SHA-256 digests, mirroring how ApiKey treats its tokens: a database
  # dump must not hand out live credentials.
  hash_token_secrets

  # OAuth 2.1 requires HTTPS redirect URIs, with an explicit carve-out for
  # loopback: MCP clients run on the user's machine and listen on 127.0.0.1.
  force_ssl_in_redirect_uri do |uri|
    !%w[localhost 127.0.0.1 ::1 [::1]].include?(uri.host)
  end
  allow_blank_redirect_uri false

  # Resource Indicators (RFC 8707). Doorkeeper copies this parameter from the
  # authorization request onto the grant and then onto the access token, which is
  # what lets McpController verify a token was minted for *this* resource.
  custom_access_token_attributes [ :resource ]

  realm "mp-crawler"
  handle_auth_errors :render
end
