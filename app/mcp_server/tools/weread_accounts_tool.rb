# frozen_string_literal: true

module Tools
  # 列出微信读书转发账号池（vid、昵称、状态、当日限流），不含 token 凭据。
  class WereadAccountsTool < MCP::Tool
    tool_name "weread_accounts"
    description "列出微信读书（WeRead）转发账号池：vid、昵称、状态、当日限流情况（不含 token 凭据）。用于判断是否需要重新扫码登录。"
    annotations(read_only_hint: true, destructive_hint: false)

    STATUS_LABELS = { 0 => "invalid", 1 => "active", 2 => "disabled" }.freeze

    def self.call(server_context:)
      accounts = Option.weread_accounts
      blocked = WereadApiClient.blocked_account_ids

      result = {
        total: accounts.size,
        enabled: accounts.count { |a| a["status"].to_i == 1 },
        blocked_today: blocked,
        accounts: accounts.map { |a|
          status_code = a["status"].to_i
          {
            vid: a["vid"].to_s,
            name: a["name"].to_s,
            status: STATUS_LABELS.fetch(status_code, "unknown"),
            status_code: status_code,
            blocked_today: blocked.include?(a["vid"].to_s),
          }
        },
      }

      MCP::Tool::Response.new([{ type: "text", text: result.to_json }])
    end
  end
end
