MCP.configure do |config|
  config.exception_reporter = ->(exception, server_context) {
    Rails.logger.error("[MCP] #{exception.class}: #{exception.message}")
  }

  # Capture tool result size in Current *before* instrumentation_callback fires.
  # around_request wraps the tool execution; instrumentation_callback fires in
  # the ensure block after around_request returns, so the attribute is set by then.
  config.around_request = ->(data, &block) {
    result = block.call
    if data[:method] == "tools/call"
      Current.mcp_response_size = result.to_json.bytesize
    end
    result
  }

  config.instrumentation_callback = ->(data) {
    Rails.logger.info("[MCP] #{data[:method]} tool=#{data[:tool_name]} duration=#{data[:duration]}s")
    McpToolCall.record!(data) if McpToolCall::LOGGED_METHODS.include?(data[:method])
  }
end
