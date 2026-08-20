class AddResponseSizeToMcpToolCalls < ActiveRecord::Migration[8.1]
  def change
    add_column :mcp_tool_calls, :response_size, :integer
  end
end
