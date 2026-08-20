# frozen_string_literal: true

module Tools
  # 查询微信读书登录结果：在服务端短轮询转发服务，成功后写入账号池。
  #
  # 默认使用最近一次由本 API Key 发起的会话（WereadLoginSession 缓存），
  # 也可显式传入 uuid。轮询用无 retry 的短超时连接，把单次往返控制在有界时间内。
  class WereadLoginStatusTool < MCP::Tool
    tool_name "weread_login_status"
    description "查询微信读书（WeRead）登录结果：服务端短轮询扫码状态，登录成功后把账号写入账号池。需先调用 weread_login_start 获取二维码。"
    annotations(read_only_hint: false, destructive_hint: false)

    input_schema(
      properties: {
        uuid: { type: "string", description: "登录会话 ID；不传则使用最近一次由本 API Key 发起的登录会话" },
        wait_seconds: { type: "integer", description: "服务端最多轮询秒数（默认 20，最大 55）" },
      }
    )

    POLL_TIMEOUT = 5

    def self.call(server_context:, uuid: nil, wait_seconds: 20)
      api_key_id = Current.mcp_api_key&.id
      uuid = uuid.presence || (Tools::WereadLoginSession.fetch(api_key_id) if api_key_id)

      if uuid.blank?
        return error("未找到登录会话：请先调用 weread_login_start 获取二维码，或在 uuid 参数中传入会话 ID")
      end

      wait_seconds = [[wait_seconds.to_i, 1].max, 55].min
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_seconds
      all_failed = true

      loop do
        begin
          data = WereadApiClient.get_login_result(uuid, timeout: POLL_TIMEOUT, allow_retry: false)
          all_failed = false

          if data["vid"].present? && data["token"].present?
            username = WereadApiClient.save_login_result(data)
            Tools::WereadLoginSession.clear(api_key_id) if api_key_id
            return ok(status: "success", username: username, vid: data["vid"].to_s, total_accounts: Option.weread_accounts.size)
          end

          msg = data["message"].to_s
          if msg.match?(/过期|expired/i)
            Tools::WereadLoginSession.clear(api_key_id) if api_key_id
            return ok(status: "expired", message: "二维码已过期，请重新调用 weread_login_start")
          end

          return ok(status: "scanned", message: msg.presence || "已扫码，请在手机上确认登录") if msg.match?(/扫描|scan|已扫码/i)
        rescue WereadApiClient::ApiError => e
          # 单次超时/网络抖动当作"仍在等待"，继续轮询；若始终失败则在预算耗尽后报错
          last_error = e
        end

        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 1
      end

      return error("无法连接微信读书转发服务，请稍后重试：#{last_error.message}") if all_failed && defined?(last_error)

      ok(status: "waiting", message: "尚未扫码，二维码约 2 分钟有效，请稍后再次调用 weread_login_status")
    end

    def self.ok(payload)
      MCP::Tool::Response.new([{ type: "text", text: payload.to_json }])
    end

    def self.error(message)
      MCP::Tool::Response.new([{ type: "text", text: message }], error: true)
    end
  end
end
