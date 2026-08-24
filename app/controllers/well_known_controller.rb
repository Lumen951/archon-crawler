# OAuth discovery documents. These are what turn "401, give up" into "401, let
# me walk the user through authorization" for an MCP client.
#
# Everything is derived from request.base_url so the documents stay correct
# behind whatever host and proxy the app is deployed under.
class WellKnownController < ActionController::API
  before_action :verify_resource_path

  # RFC 9728 — Protected Resource Metadata. Step one of discovery: tells the
  # client which authorization server guards this MCP endpoint.
  def protected_resource
    render json: {
      resource: McpOauth.resource_identifier(base_url),
      authorization_servers: [ base_url ],
      scopes_supported: McpOauth::SCOPES,
      bearer_methods_supported: [ "header" ],
      resource_name: "MP-Crawler MCP",
      resource_documentation: "#{base_url}/mcp"
    }
  end

  # RFC 8414 — Authorization Server Metadata. Step two: the endpoints and
  # capabilities the client needs to run the authorization code flow.
  def authorization_server
    render json: {
      issuer: base_url,
      authorization_endpoint: "#{base_url}/oauth/authorize",
      token_endpoint: "#{base_url}/oauth/token",
      registration_endpoint: "#{base_url}/oauth/register",
      revocation_endpoint: "#{base_url}/oauth/revoke",
      introspection_endpoint: "#{base_url}/oauth/introspect",
      scopes_supported: McpOauth::SCOPES,
      response_types_supported: [ "code" ],
      response_modes_supported: [ "query" ],
      grant_types_supported: %w[authorization_code refresh_token],
      token_endpoint_auth_methods_supported: %w[none client_secret_post client_secret_basic],
      code_challenge_methods_supported: [ "S256" ],
      # Doorkeeper does not emit the RFC 9207 `iss` parameter on authorization
      # responses. Advertising false is the honest answer and keeps clients from
      # rejecting the response for a missing `iss` (spec §Authorization Response
      # Validation); revisit if Doorkeeper gains support.
      authorization_response_iss_parameter_supported: false,
      service_documentation: "#{base_url}/mcp"
    }
  end

  private

  def base_url = request.base_url

  # The path-inserted form of these URLs names a specific resource. Only this
  # app's MCP endpoint exists, so anything else is a 404 rather than a document
  # describing a resource we do not serve.
  def verify_resource_path
    return if params[:resource_path].blank?
    return if "/#{params[:resource_path]}".chomp("/") == McpOauth::MCP_PATH

    head :not_found
  end
end
