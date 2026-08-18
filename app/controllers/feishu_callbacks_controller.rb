# 飞书消息卡片回调端点。
#
# 飞书自建应用的「卡片回调地址」指向 /feishu/card_callback。用户点击卡片按钮后，
# 飞书 POST 回调数据（含 operator.open_id 与 action.value），本控制器验签、解析后
# 入队 WereadLoginForUserJob，并在 3 秒内返回 toast 响应。
class FeishuCallbacksController < ApplicationController
  allow_unauthenticated_access
  # 飞书服务器 POST 无 CSRF token，跳过 Rails 默认的 CSRF 校验
  skip_before_action :verify_authenticity_token

  def card
    payload = parse_payload

    # 1. URL 校验：后台保存回调地址时，飞书发送 type=url_verification + challenge
    if url_verification?(payload)
      return render json: { challenge: params[:challenge].presence || payload["challenge"] }
    end

    # 2. 验签
    unless FeishuNotifier.verify_signature?(
      timestamp: request.headers["X-Lark-Request-Timestamp"],
      nonce: request.headers["X-Lark-Request-Nonce"],
      signature: request.headers["X-Lark-Signature"],
      body: request.raw_post
    )
      return render json: { code: 1, msg: "invalid signature" }, status: :unauthorized
    end

    # 3. 解析点击者与按钮动作
    open_id = payload.dig("operator", "open_id").presence || payload["open_id"]
    action = extract_action(payload.dig("action", "value") || payload["value"])

    # 4. 分发：命中登录按钮且能拿到点击者 open_id 时，异步生成专属二维码
    WereadLoginForUserJob.perform_later(open_id) if action == "weread_login" && open_id.present?

    # 5. 3 秒内返回，避免飞书交互超时
    render json: { toast: { type: "success", content: "已开始为你生成登录二维码，请查看与机器人的私聊" } }
  end

  private

  def parse_payload
    JSON.parse(request.raw_post.to_s)
  rescue JSON::ParserError
    {}
  end

  # 兼容 query 参数与 body 两种 URL 校验形式
  def url_verification?(payload)
    (params[:type] == "url_verification" || payload["type"] == "url_verification") &&
      (params[:challenge].present? || payload["challenge"].present?)
  end

  # 按钮 value 可能是对象（{action: "..."}）或 JSON 字符串，统一提取 action 值
  def extract_action(value)
    return value["action"] if value.is_a?(Hash)
    return value unless value.is_a?(String)

    parsed = JSON.parse(value) rescue nil
    parsed.is_a?(Hash) ? parsed["action"] : value
  end
end
