module Tools
  class ListEventResearchRunsTool < MCP::Tool
    tool_name "list_event_research_runs"
    description "查询活动调研（Event Research）的运行记录列表：状态、获奖/人物/公司计数、时间与错误信息。配合 get_event_research_result 获取完整调研数据。"
    annotations(read_only_hint: true, destructive_hint: false)

    input_schema(
      properties: {
        account_id: { type: "integer", description: "活动账号 ID（可选）" },
        status: { type: "string", description: "按状态过滤（可选：pending / running / completed / failed）" },
        latest: { type: "boolean", description: "为 true 时只返回每个账号最近一次成功调研（默认 false）" },
        page: { type: "integer", description: "页码（默认 1）" },
        per_page: { type: "integer", description: "每页数量（默认 25，最大 100）" }
      },
      required: []
    )

    def self.call(server_context:, account_id: nil, status: nil, latest: false, page: 1, per_page: 25)
      if account_id.present? && EventAccount.find_by(id: account_id).nil?
        return MCP::Tool::Response.new(
          [{ type: "text", text: "未找到 ID 为 #{account_id} 的活动账号" }],
          error: true
        )
      end

      if status.present? && !EventResearchRun.statuses.key?(status.to_s)
        return MCP::Tool::Response.new(
          [{ type: "text", text: "无效的 status，可选值：#{EventResearchRun.statuses.keys.join('、')}" }],
          error: true
        )
      end

      account_scope = EventResearchRun.all
      account_scope = account_scope.where(account_id: account_id) if account_id.present?

      if latest
        ids = latest_completed_ids(account_scope)
        scope = EventResearchRun.where(id: ids).recent.includes(:account)
      else
        scope = account_scope.recent.includes(:account)
        scope = scope.where(status: status) if status.present?
      end

      page = [ page.to_i, 1 ].max
      per_page = [ [ per_page.to_i, 25 ].max, 100 ].min
      runs = scope.page(page).per(per_page)

      result = {
        total_count: runs.total_count,
        page: runs.current_page,
        per_page: runs.limit_value,
        total_pages: runs.total_pages,
        runs: runs.map { |run| run_json(run) }
      }

      MCP::Tool::Response.new([{ type: "text", text: result.to_json }])
    end

    def self.run_json(run)
      {
        id: run.id,
        account: { id: run.account.id, nickname: run.account.nickname },
        status: run.status,
        award_count: run.award_count,
        people_count: run.people_count,
        company_count: run.company_count,
        error_message: run.error_message,
        started_at: run.started_at&.iso8601,
        completed_at: run.completed_at&.iso8601,
        created_at: run.created_at.iso8601
      }
    end

    def self.latest_completed_ids(account_scope)
      account_scope.where(status: :completed)
                   .order(:account_id, created_at: :desc)
                   .select("DISTINCT ON (account_id) id")
                   .map(&:id)
    end
  end
end
