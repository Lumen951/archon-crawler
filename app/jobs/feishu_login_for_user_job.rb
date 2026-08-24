# 为单个飞书用户生成专属扫码登录二维码，私聊推送并轮询登录结果。
#
# 由 FeishuCallbacksController 在用户点击卡片按钮后入队，每个 open_id 各自一份
# 登录会话——微信读书借此形成多账号池；微信公众号平台只有一个会话槽位，
# 多人同时扫码时最后登录成功者胜出（都是合法会话，不会互相污染）。
class FeishuLoginForUserJob < ApplicationJob
  include QrLogin::Polling

  queue_as :default

  def perform(provider_key, open_id)
    provider = QrLogin.find(provider_key)
    session = provider.start

    FeishuNotifier.send_qr_login_to(
      open_id: open_id,
      png_bytes: session[:image_bytes],
      text: "请用微信扫描上方二维码完成#{provider.label}登录，二维码约 2 分钟有效。"
    )

    result = poll_until_done(provider, session[:handle])
    FeishuNotifier.send_text(result_text(provider, result), receive_id: open_id, receive_id_type: "open_id")
    Rails.logger.info("[FeishuLoginForUserJob] #{provider.label} 轮询结束: #{result[:status]}")
  rescue FeishuNotifier::Error => e
    Rails.logger.error("[FeishuLoginForUserJob] 飞书推送失败: #{e.message}")
  rescue StandardError => e
    Rails.logger.error("[FeishuLoginForUserJob] #{provider_key} 获取二维码失败: #{e.message}")
  end

  private

  def result_text(provider, result)
    case result[:status]
    when :success then provider.success_text(result[:identity])
    when :expired, :timeout then "⏰ #{provider.label}二维码已过期，请重新点击登录按钮获取新二维码"
    else "⚠️ #{provider.label}登录失败：#{result[:message].presence || '未知错误'}"
    end
  end
end
