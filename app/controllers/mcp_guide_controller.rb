class McpGuideController < ApplicationController
  # allow_unauthenticated_access only: [:show]

  def show
    @api_keys = current_user&.api_keys&.order(created_at: :desc) || []
    @new_token = flash[:api_key_token]
    @mcp_endpoint_url = "#{request.base_url}/mcp/endpoint"
  end

  def create_token
    name = params[:token_name].to_s.strip.presence || "MCP Client"
    api_key = current_user.api_keys.build(name: name)

    if api_key.save
      flash[:api_key_token] = api_key.token
      flash[:notice] = "Token \"#{name}\" 已创建"
    else
      flash[:error] = "创建失败：#{api_key.errors.full_messages.join(', ')}"
    end

    redirect_to mcp_guide_path
  end

  def revoke_token
    api_key = current_user.api_keys.find(params[:id])
    api_key.update!(active: false)
    flash[:notice] = "Token \"#{api_key.name}\" 已撤销"
  rescue ActiveRecord::RecordNotFound
    flash[:error] = "未找到该 Token"
  ensure
    redirect_to mcp_guide_path
  end
end
