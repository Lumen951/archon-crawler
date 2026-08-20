class CreateMcpToolCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_tool_calls do |t|
      t.references :user, foreign_key: true
      t.references :api_key, foreign_key: true
      t.string :method, null: false
      t.string :tool_name
      t.jsonb :arguments, default: {}
      t.integer :status, default: 0, null: false  # success: 0, error: 1
      t.string :error_type
      t.integer :duration_ms
      t.string :ip_address
      t.timestamps
    end

    add_index :mcp_tool_calls, :created_at
    add_index :mcp_tool_calls, :method
    add_index :mcp_tool_calls, :tool_name
  end
end
