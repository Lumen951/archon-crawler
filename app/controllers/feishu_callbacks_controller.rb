# 飞书消息卡片回调端点。
#
# 飞书自建应用的「卡片回调地址」指向 /feishu/card_callback。用户点击卡片按钮后，
# 飞书 POST 回调数据（含 operator.open_id 与 action.value），本控制器解密、验签、解析后
# 按 action 值找到对应的扫码登录平台（QrLogin.find_by_card_action，如 "weread_login" /
# "wechat_mp_login"）并入队 FeishuLoginForUserJob，最后在 3 秒内返回 toast 响应。
#
# 飞书开启加密策略时，body 为 {"encrypt": "<base64>"}，需先 AES 解密得到明文回调。
class FeishuCallbacksController < ApplicationController
  allow_unauthenticated_access
  # 飞书服务器 POST 无 CSRF token，跳过 Rails 默认的 CSRF 校验
  skip_before_action :verify_authenticity_token

  def card
    raw_body = request.raw_post.to_s
    Rails.logger.info(
      "[Feishu] 收到卡片回调 method=#{request.method} path=#{request.fullpath} " \
      "content_type=#{request.headers['Content-Type']} " \
      "timestamp=#{request.headers['X-Lark-Request-Timestamp'].inspect} " \
      "nonce=#{request.headers['X-Lark-Request-Nonce'].inspect} " \
      "signature=#{request.headers['X-Lark-Signature'].inspect}"
    )
    Rails.logger.info("[Feishu] 原始 body: #{raw_body}")
    Rails.logger.info("[Feishu] query 参数: #{request.query_parameters.inspect}")

    payload = parse_json(raw_body)
    Rails.logger.info("[Feishu] 解析后 payload: #{payload.inspect}")

    # 1. 解密（飞书开启加密时，body 为 {"encrypt": "..."}）
    if payload["encrypt"].present?
      Rails.logger.info("[Feishu] 检测到加密回调，开始解密 encrypt=#{payload['encrypt'][0, 32]}...")
      decrypted = FeishuNotifier.decrypt_callback(payload["encrypt"])
      Rails.logger.info("[Feishu] 解密后明文: #{decrypted.inspect}")
      payload = parse_json(decrypted)
      Rails.logger.info("[Feishu] 解密后 payload: #{payload.inspect}")
    else
      Rails.logger.info("[Feishu] 非加密回调，跳过解密")
    end

    # 2. URL 校验：后台保存回调地址时，飞书发送 type=url_verification + challenge
    if url_verification?(payload)
      challenge = payload["challenge"].presence || request.query_parameters["challenge"]
      Rails.logger.info("[Feishu] 命中 URL 校验，返回 challenge=#{challenge.inspect}")
      return render json: { challenge: challenge }
    end

    # 3. 验签（对原始请求体，加密时即 {"encrypt": "..."} 密文本身）
    signature_valid = FeishuNotifier.verify_signature?(
      timestamp: request.headers["X-Lark-Request-Timestamp"],
      nonce: request.headers["X-Lark-Request-Nonce"],
      signature: request.headers["X-Lark-Signature"],
      body: raw_body
    )
    unless signature_valid
      Rails.logger.warn("[Feishu] 验签失败，返回 401")
      return render json: { code: 1, msg: "invalid signature" }, status: :unauthorized
    end
    Rails.logger.info("[Feishu] 验签通过")

    # 4. 解析点击者与按钮动作（飞书事件回调 v2.0 将数据包裹在 event 下，v1.0 为扁平结构）
    event = payload["event"].is_a?(Hash) ? payload["event"] : payload
    open_id = event.dig("operator", "open_id").presence || payload["open_id"]
    action_value = event.dig("action", "value") || payload["value"]
    action = extract_action(action_value)
    Rails.logger.info(
      "[Feishu] 解析结果 operator_open_id=#{event.dig('operator', 'open_id').inspect} " \
      "open_id=#{payload['open_id'].inspect} 最终 open_id=#{open_id.inspect} " \
      "action_value=#{action_value.inspect} 最终 action=#{action.inspect}"
    )

    # 5. 分发：命中某个平台的登录按钮且能拿到点击者 open_id 时，异步生成专属二维码
    provider = QrLogin.find_by_card_action(action)
    if provider && open_id.present?
      Rails.logger.info("[Feishu] 命中 #{provider.label} 登录按钮，入队 FeishuLoginForUserJob open_id=#{open_id.inspect}")
      FeishuLoginForUserJob.perform_later(provider.key, open_id)
    else
      Rails.logger.info("[Feishu] 未触发登录分发（action=#{action.inspect} open_id=#{open_id.inspect}）")
    end

    # 6. 3 秒内返回，避免飞书交互超时
    Rails.logger.info("[Feishu] 处理完成，返回成功 toast")
    render json: { toast: { type: "success", content: "已开始为你生成登录二维码，请查看与机器人的私聊" } }
  rescue FeishuNotifier::Error => e
    Rails.logger.error("[Feishu] 回调处理失败: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
    render json: { code: 1, msg: "invalid request" }, status: :bad_request
  rescue => e
    Rails.logger.error("[Feishu] 未预期异常: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
    render json: { code: 1, msg: "invalid request" }, status: :bad_request
  end

  private

  def parse_json(str)
    JSON.parse(str.to_s)
  rescue JSON::ParserError
    {}
  end

  # 兼容 query 参数与 body 两种 URL 校验形式
  def url_verification?(payload)
    type = payload["type"] || request.query_parameters["type"]
    challenge = payload["challenge"] || request.query_parameters["challenge"]
    type == "url_verification" && challenge.present?
  end

  # 按钮 value 可能是对象（{action: "..."}）或 JSON 字符串，统一提取 action 值
  def extract_action(value)
    return value["action"] if value.is_a?(Hash)
    return value unless value.is_a?(String)

    parsed = JSON.parse(value) rescue nil
    parsed.is_a?(Hash) ? parsed["action"] : value
  end
end
