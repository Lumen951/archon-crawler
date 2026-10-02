module Tools
  class GetEventResearchResultTool < MCP::Tool
    tool_name "get_event_research_result"
    description "获取一次活动调研的完整结果 JSON（获奖名单、人物教育/任职/联系方式、公司工商档案与来源出处）。传 run_id 取指定运行；或传 account_id 取该账号最近一次成功调研。"
    annotations(read_only_hint: true, destructive_hint: false)

    input_schema(
      properties: {
        run_id: { type: "integer", description: "调研运行 ID（与 account_id 二选一）" },
        account_id: { type: "integer", description: "活动账号 ID，取其最近一次成功调研（与 run_id 二选一）" }
      },
      required: []
    )

    def self.call(server_context:, run_id: nil, account_id: nil)
      run =
        if run_id.present?
          EventResearchRun.find_by(id: run_id)
        elsif account_id.present?
          account = EventAccount.find_by(id: account_id)
          return missing("ID 为 #{account_id} 的活动账号") if account.nil?

          EventResearchRun.latest_completed_for(account)
        end

      return missing("ID 为 #{run_id} 的调研运行") if run.nil?
      return MCP::Tool::Response.new(
        [{ type: "text", text: "Run ##{run.id} 状态为 #{run.status}，尚无可用的调研结果#{run.error_message.present? ? "（#{run.error_message}）" : ''}" }],
        error: true
      ) if run.result.blank?

      MCP::Tool::Response.new([{ type: "text", text: run.result.to_json }])
    end

    def self.missing(label)
      MCP::Tool::Response.new([{ type: "text", text: "未找到#{label}" }], error: true)
    end
  end
end
