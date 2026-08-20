MCP.configure do |config|
  config.exception_reporter = ->(exception, server_context) {
    Rails.logger.error("[MCP] #{exception.class}: #{exception.message}")
  }

  config.instrumentation_callback = ->(data) {
    Rails.logger.info("[MCP] #{data[:method]} tool=#{data[:tool_name]} duration=#{data[:duration]}s")
    McpToolCall.record!(data) if McpToolCall::LOGGED_METHODS.include?(data[:method])
  }
end
