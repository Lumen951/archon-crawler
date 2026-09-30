class McpController < ActionController::API
  before_action :authenticate_mcp_request!
  before_action :authorize_tool_scope!

  TOOLS = [
    Tools::ListAccountsTool,
    Tools::GetAccountTool,
    Tools::ListArticlesTool,
    Tools::SearchArticlesTool,
    Tools::UpdateAccountsTool,
    Tools::BatchUpdateAccountsByFilterTool,
    Tools::ListTagsTool,
    Tools::GetActivityStatsTool,
    Tools::WereadLoginStartTool,
    Tools::WereadLoginStatusTool,
    Tools::WereadAccountsTool
  ].freeze

  # POST/GET/DELETE /mcp/endpoint
  def endpoint
    server = MCP::Server.new(
      name: "mp-crawler",
      version: "1.0.0",
      instructions: "MP-Crawler 公众号/小红书/Twitter 文章管理平台 — 管理账号、查看文章、分析活跃度、批量操作标签。",
      tools: TOOLS,
      server_context: {
        user: @current_user,
        api_key: @current_api_key,
        access_token: @current_access_token
      },
    )

    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      dns_rebinding_protection: false,
    )
    status, headers, body = transport.handle_request(request)

    response.headers.merge!(headers)
    render json: body.first, status: status
  end

  private

  # Two credential types are accepted: OAuth access tokens minted by this app's
  # authorization server (the discoverable path MCP clients drive themselves),
  # and long-lived ApiKeys (scripts, CI, the device flow).
  def authenticate_mcp_request!
    token = extract_bearer_token

    # RFC 6750 §3: when the request carries no credentials at all, challenge
    # without an error code. This is the response that tells an MCP client the
    # server speaks OAuth and where to look next.
    return challenge!(:unauthorized, description: "Missing Bearer token") if token.blank?

    @current_access_token = Doorkeeper::AccessToken.by_token(token)

    if @current_access_token
      authenticate_oauth_token or return
    else
      authenticate_api_key(token) or return
    end

    Current.mcp_user    = @current_user
    Current.mcp_api_key = @current_api_key
    Current.mcp_ip      = request.remote_ip
  end

  def authenticate_oauth_token
    unless @current_access_token.accessible?
      challenge!(:unauthorized, error: "invalid_token", description: "The access token is expired or revoked")
      return false
    end

    unless correct_audience?(@current_access_token)
      challenge!(:unauthorized, error: "invalid_token", description: "The access token was not issued for this resource")
      return false
    end

    @current_user = User.find_by(id: @current_access_token.resource_owner_id)

    if @current_user.nil?
      challenge!(:unauthorized, error: "invalid_token", description: "The access token has no valid resource owner")
      return false
    end

    true
  end

  def authenticate_api_key(token)
    @current_api_key = ApiKey.find_by_token(token)

    if @current_api_key.nil?
      challenge!(:unauthorized, error: "invalid_token", description: "Invalid token")
      return false
    end

    @current_user = @current_api_key.user
    true
  end

  # This authorization server only ever issues tokens for this MCP endpoint, so
  # an unbound token (older clients omit the `resource` parameter) is still ours.
  # When the client did bind it per RFC 8707, the binding has to match.
  def correct_audience?(access_token)
    access_token.resource.blank? ||
      McpOauth.matches_resource?(access_token.resource, request.base_url)
  end

  # Mutating tools need mcp:write; everything else needs mcp:read. A client that
  # is short a scope gets a 403 with an insufficient_scope challenge, which is
  # what triggers its step-up authorization flow.
  def authorize_tool_scope!
    return if @current_access_token.nil?

    required = required_scope
    return if required.nil? || @current_access_token.scopes.include?(required)

    challenge!(
      :forbidden,
      error: "insufficient_scope",
      description: "This operation requires the #{required} scope",
      scope: required
    )
  end

  def required_scope
    calls = rpc_messages.select { |message| message["method"] == "tools/call" }
    return nil if calls.empty?

    if calls.any? { |message| McpOauth.write_tool?(message.dig("params", "name")) }
      McpOauth::WRITE_SCOPE
    else
      McpOauth::READ_SCOPE
    end
  end

  # Peek at the JSON-RPC body to see which tool is being called. raw_post rewinds
  # the body afterwards, so the transport still reads it in full.
  def rpc_messages
    @rpc_messages ||= begin
      payload = JSON.parse(request.raw_post.presence || "{}")
      Array.wrap(payload).select { |message| message.is_a?(Hash) }
    rescue JSON::ParserError
      []
    end
  end

  def challenge!(status, description:, error: nil, scope: McpOauth::SCOPES.join(" "))
    response.headers["WWW-Authenticate"] = McpOauth.challenge(
      request.base_url,
      error: error,
      error_description: description,
      scope: scope
    )
    render json: { error: error || "unauthorized", error_description: description }, status: status
  end

  def extract_bearer_token
    header = request.headers["Authorization"]
    header&.match(/\ABearer (.+)\z/)&.captures&.first
  end
end
