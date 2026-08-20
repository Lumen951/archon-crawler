class McpController < ActionController::API
  before_action :authenticate_mcp_token!

  # POST/GET/DELETE /mcp/endpoint
  def endpoint
    tools = [
      Tools::ListAccountsTool,
      Tools::GetAccountTool,
      Tools::ListArticlesTool,
      Tools::UpdateAccountsTool,
      Tools::ListTagsTool,
      Tools::GetActivityStatsTool,
    ]

    server = MCP::Server.new(
      name: "mp-crawler",
      version: "1.0.0",
      instructions: "MP-Crawler 公众号/小红书/Twitter 文章管理平台 — 管理账号、查看文章、分析活跃度、批量操作标签。",
      tools: tools,
      server_context: { user: @current_user, api_key: @current_api_key },
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

  def authenticate_mcp_token!
    token = extract_bearer_token

    if token.blank?
      render json: { error: "Unauthorized: missing Bearer token" }, status: :unauthorized
      return
    end

    @current_api_key = ApiKey.find_by_token(token)

    if @current_api_key.nil?
      render json: { error: "Unauthorized: invalid token" }, status: :unauthorized
      return
    end

    @current_user = @current_api_key.user
  end

  def extract_bearer_token
    header = request.headers["Authorization"]
    header&.match(/\ABearer (.+)\z/)&.captures&.first
  end
end
