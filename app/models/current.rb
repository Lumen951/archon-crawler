class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :mcp_user, :mcp_api_key, :mcp_ip, :mcp_response_size
end
