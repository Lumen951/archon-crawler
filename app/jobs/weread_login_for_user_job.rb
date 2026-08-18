require "rqrcode"
require "rqrcode_png"

# 为单个飞书用户生成专属微信读书登录二维码，私聊推送并轮询登录结果。
#
# 由 FeishuCallbacksController 在用户点击卡片按钮后入队，每个 open_id 各自一份
# 登录会话，从而支持多人各自扫码形成账号池。
class WereadLoginForUserJob < ApplicationJob
  queue_as :default

  POLL_INTERVAL = 5               # 轮询间隔（秒）
  POLL_TIMEOUT = 5.minutes        # 最多轮询多久

  def perform(open_id)
    result = WereadApiClient.create_login_url
    uuid = result["uuid"]
    scan_url = result["scanUrl"]

    png_bytes = generate_qr_png(scan_url)
    FeishuNotifier.send_qr_login_to(
      open_id: open_id,
      png_bytes: png_bytes,
      text: "请用微信扫描上方二维码完成微信读书登录，二维码约 2 分钟有效。"
    )

    poll_login(open_id, uuid)
  rescue FeishuNotifier::Error => e
    Rails.logger.error("[WereadLoginForUserJob] 飞书推送失败: #{e.message}")
  rescue WereadApiClient::ApiError => e
    Rails.logger.error("[WereadLoginForUserJob] 获取登录二维码失败: #{e.message}")
  end

  private

  def poll_login(open_id, uuid)
    deadline = Time.current + POLL_TIMEOUT

    loop do
      data = WereadApiClient.get_login_result(uuid)

      if data["vid"] && data["token"]
        username = WereadApiClient.save_login_result(data)
        FeishuNotifier.send_text("✅ 微信读书登录成功：#{username}", receive_id: open_id, receive_id_type: "open_id")
        Rails.logger.info("[WereadLoginForUserJob] 登录成功：#{username}")
        return
      end

      break if Time.current > deadline
      sleep POLL_INTERVAL
    end

    FeishuNotifier.send_text("⏰ 微信读书二维码已过期，请重新点击登录按钮获取新二维码", receive_id: open_id, receive_id_type: "open_id")
    Rails.logger.info("[WereadLoginForUserJob] 二维码过期")
  rescue WereadApiClient::ApiError => e
    Rails.logger.error("[WereadLoginForUserJob] 轮询登录状态失败: #{e.message}")
  end

  def generate_qr_png(scan_url)
    RQRCode::QRCode.new(scan_url).as_png(size: 400, border_modules: 2).to_s
  end
end
