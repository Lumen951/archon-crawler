# 定时任务：提醒扫码登录（微信读书 / 微信公众号平台）。
#
# 平台差异全部由 QrLogin 策略吸收，本 Job 只负责「要不要推」和「怎么推」：
#   - 要不要推：provider.reminder_needed?
#       · 微信读书恒为 true（持续扩充账号池）
#       · 微信公众号平台仅在 validate_session 探测到会话失效时为 true
#   - 怎么推（Option.feishu_login_mode，两个平台共用）：
#       · "qr"（默认）：直接推一张二维码到配置的会话，后台轮询登录结果
#       · "card"：推一张带「我要登录」按钮的交互卡片，成员点击后由
#         FeishuCallbacksController 入队 FeishuLoginForUserJob，各自私聊收到专属二维码
#
# 未配置飞书（FeishuNotifier.enabled? 为 false）时直接跳过，不报错。
class FeishuLoginReminderJob < ApplicationJob
  include QrLogin::Polling

  queue_as :default

  def perform(provider_key)
    provider = QrLogin.find(provider_key)

    unless FeishuNotifier.enabled?
      Rails.logger.info("[FeishuLoginReminderJob] 飞书推送未配置，跳过 #{provider_key}")
      return
    end

    # unless provider.reminder_needed?
    #   Rails.logger.info("[FeishuLoginReminderJob] #{provider.label}无需登录提醒，跳过")
    #   return
    # end

    if Option.feishu_login_card_mode?
      send_login_card(provider)
    else
      send_single_qr(provider)
    end
  rescue QrLogin::Error => e
    Rails.logger.error("[FeishuLoginReminderJob] #{provider_key} 失败: #{e.message}")
  end

  private

  # 模式一：直接推一张二维码，并在后台轮询登录结果
  def send_single_qr(provider)
    session = provider.start
    FeishuNotifier.send_qr_login(png_bytes: session[:image_bytes], text: provider.qr_prompt_text)

    result = poll_until_done(provider, session[:handle])
    FeishuNotifier.send_text(result_text(provider, result))
    Rails.logger.info("[FeishuLoginReminderJob] #{provider.label} 轮询结束: #{result[:status]}")
  rescue FeishuNotifier::Error => e
    Rails.logger.error("[FeishuLoginReminderJob] 飞书推送失败: #{e.message}")
  rescue StandardError => e
    Rails.logger.error("[FeishuLoginReminderJob] #{provider.label} 获取二维码失败: #{e.message}")
  end

  # 模式二：推交互卡片，成员各自点击后私聊专属二维码
  def send_login_card(provider)
    FeishuNotifier.send_card(provider.card)
  rescue FeishuNotifier::Error => e
    Rails.logger.error("[FeishuLoginReminderJob] 飞书推送卡片失败: #{e.message}")
  end

  def result_text(provider, result)
    case result[:status]
    when :success then provider.success_text(result[:identity])
    when :expired, :timeout then provider.expired_text
    else "⚠️ #{provider.label}登录失败：#{result[:message].presence || '未知错误'}"
    end
  end
end
