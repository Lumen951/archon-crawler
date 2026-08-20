# frozen_string_literal: true

require "rqrcode"

module Tools
  # 发起微信读书登录，返回终端可显示的 ASCII/Unicode 二维码（非 PNG）。
  #
  # 复用 WereadApiClient.create_login_url 获取 {uuid, scanUrl}，用 QrAscii 渲染成
  # 半块/全块字符画。返回三个 content item：裸二维码、给 assistant 的逐字输出指令、
  # 以及 JSON 元数据（含 uuid / scan_url 兜底）。
  class WereadLoginStartTool < MCP::Tool
    tool_name "weread_login_start"
    description "发起微信读书（WeRead）登录：生成终端可显示的 ASCII/Unicode 二维码（非图片）。用户用微信「扫一扫」扫码后，再调用 weread_login_status 查询登录结果。"
    annotations(read_only_hint: false, destructive_hint: false)

    input_schema(
      properties: {
        invert: { type: "boolean", description: "浅色背景终端设为 true（默认 false，适配深色终端）" },
        style: { type: "string", enum: %w[half_block full_block], description: "二维码渲染风格：half_block（默认，紧凑半块字符）/ full_block（每模块两字符，更宽）" },
      }
    )

    INSTRUCTION = "请把上面这段二维码原样输出给用户：用一对 ``` 包裹成 fenced code block；把每个 `\\n` 还原为换行，逐字符完整复制每一行（包括行首行尾空格与 █ ▀ ▄ 字符），不要省略、不要重排、不要替换任何字符。同时告诉用户：用微信「扫一扫」扫描该二维码即可完成微信读书登录，二维码约 2 分钟有效；扫码后请再次调用 weread_login_status 查询登录结果。"

    def self.call(server_context:, invert: false, style: "half_block")
      if Option.weread_platform_url.blank?
        return error("微信读书转发服务地址未配置")
      end

      result = WereadApiClient.create_login_url
      uuid = result["uuid"]
      scan_url = result["scanUrl"]

      if uuid.blank? || scan_url.blank?
        return error("获取登录二维码失败：转发服务返回数据不完整")
      end

      style = style.to_s == "full_block" ? "full_block" : "half_block"
      art = QrAscii.render(scan_url, invert: !!invert, style: style.to_sym)

      # 会话按 API Key 缓存，让 status 可不传 uuid（避免 uuid 进 mcp_tool_calls）
      Tools::WereadLoginSession.store(Current.mcp_api_key.id, uuid) if Current.mcp_api_key

      width, height = dimensions(scan_url, style)
      meta = {
        status: "waiting",
        uuid: uuid,
        scan_url: scan_url,
        width: width,
        height: height,
        style: style,
        invert: !!invert,
        expires_in_seconds: 120,
      }

      MCP::Tool::Response.new([
        { type: "text", text: art },
        { type: "text", text: INSTRUCTION },
        { type: "text", text: meta.to_json },
      ])
    rescue WereadApiClient::ApiError => e
      error("无法连接微信读书转发服务：#{e.message}")
    rescue StandardError => e
      error("生成二维码失败：#{e.message}")
    end

    def self.error(message)
      MCP::Tool::Response.new([{ type: "text", text: message }], error: true)
    end

    def self.dimensions(text, style)
      size  = RQRCode::QRCode.new(text).qrcode.module_count
      total = size + 4 # quiet_zone = 2
      style == "full_block" ? [total * 2, total] : [total, (total + 1) / 2]
    end
  end
end
