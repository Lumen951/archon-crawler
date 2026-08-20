module Tools
  class GetActivityStatsTool < MCP::Tool
    tool_name "get_activity_stats"
    description "获取各平台账号活跃度统计概览，包括活跃/减速/停更/失活/从未发布/未抓取各层级的数量分布。用于全局分析。"
    annotations(read_only_hint: true, destructive_hint: false)

    input_schema(
      properties: {}
    )

    def self.call(server_context:)
      stats = Account.platform_activity_stats

      result = {
        platforms: stats,
        summary: {
          total_accounts: stats.sum { |s| s[:total] },
          total_active: stats.sum { |s| s[:active] },
          total_dormant: stats.sum { |s| s[:dormant] + s[:dead] },
          total_never: stats.sum { |s| s[:never] + s[:uncrawled] },
        }
      }

      MCP::Tool::Response.new([{ type: "text", text: result.to_json }])
    end
  end
end
