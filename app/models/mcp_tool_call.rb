class McpToolCall < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :api_key, optional: true

  enum :status, { success: 0, error: 1 }, default: :success

  scope :recent, -> { order(created_at: :desc) }

  # MCP methods we persist. Connection/handshake noise (initialize, ping,
  # tools/list, notifications/*, ...) is intentionally excluded.
  LOGGED_METHODS = %w[tools/call resources/read prompts/get].freeze

  # Persist one tool call from the MCP gem's instrumentation data.
  # Reads the authenticated user/api key/IP from Current (set by McpController).
  # Rescue-guarded so a logging failure never breaks the MCP response itself.
  def self.record!(data)
    arguments = data[:tool_arguments].presence || {}

    create!(
      user:      Current.mcp_user,
      api_key:   Current.mcp_api_key,
      method:    data[:method],
      tool_name: data[:tool_name],
      arguments: arguments,
      status:    data[:error].present? ? :error : :success,
      error_type: data[:error].present? ? data[:error].to_s : nil,
      duration_ms: data[:duration] ? (data[:duration] * 1000).round : nil,
      ip_address: Current.mcp_ip
    )
  rescue => e
    Rails.logger.error("[MCP] failed to record tool call: #{e.class}: #{e.message}")
  end

  def target_label
    tool_name || arguments["resource_uri"] || arguments["prompt_name"] || "—"
  end

  def self.ransackable_attributes(auth_object = nil)
    %w[created_at method tool_name status user_id api_key_id ip_address error_type duration_ms]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[user api_key]
  end
end
