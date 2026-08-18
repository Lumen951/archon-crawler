require "rqrcode"
require "rqrcode_png"

# 每日定时任务：提醒微信读书（WeRead）账号登录。
#
# 支持两种推送方式（由 Option.feishu_weread_login_mode 切换）：
#   - "qr"（默认）：生成一张登录二维码推到飞书，后台轮询登录结果，扫码成功后写回账号池。
#   - "card"：发送一张带「我要登录」按钮的交互卡片，成员点击后由 FeishuCallbacksController
#     入队 WereadLoginForUserJob，各自私聊收到专属二维码，从而支持多人形成账号池。
#
# 未配置飞书（FeishuNotifier.enabled? 为 false）时直接跳过，不报错。
class WereadLoginReminderJob < ApplicationJob
  queue_as :default

  POLL_INTERVAL = 5               # 轮询间隔（秒）
  POLL_TIMEOUT = 5.minutes        # 最多轮询多久

  def perform
    unless FeishuNotifier.enabled?
      Rails.logger.info("[WereadLoginReminderJob] 飞书推送未配置，跳过")
      return
    end

    if Option.feishu_weread_login_mode == "card"
      send_login_card
    else
      send_single_qr
    end
  end

  private

  # ── 模式一：单二维码推送（默认，保留原有行为）─────────────

  def send_single_qr
    result = WereadApiClient.create_login_url
    uuid = result["uuid"]
    scan_url = result["scanUrl"]

    # 后台 Job 无浏览器 session，故持久化到 Option 供轮询使用
    Option.set("weread_pending_login_uuid", uuid)

    png_bytes = generate_qr_png(scan_url)
    FeishuNotifier.send_qr_login(png_bytes: png_bytes, text: login_prompt_text)

    poll_login(uuid)
  rescue FeishuNotifier::Error => e
    Rails.logger.error("[WereadLoginReminderJob] 飞书推送失败: #{e.message}")
    Option.delete("weread_pending_login_uuid")
  rescue WereadApiClient::ApiError => e
    Rails.logger.error("[WereadLoginReminderJob] 获取登录二维码失败: #{e.message}")
    Option.delete("weread_pending_login_uuid")
  end

  # ── 模式二：交互卡片（多人各自扫码登录）─────────────

  def send_login_card
    FeishuNotifier.send_card(login_card)
  rescue FeishuNotifier::Error => e
    Rails.logger.error("[WereadLoginReminderJob] 飞书推送卡片失败: #{e.message}")
  end

  def login_card
    {
      config: { wide_screen_mode: true },
      header: {
        template: "blue",
        title: { tag: "plain_text", content: "微信读书账号登录" }
      },
      elements: [
        {
          tag: "div",
          text: {
            tag: "lark_md",
            content: "微信读书账号已过期或需要扩充账号池。点击下方按钮，将私聊收到专属二维码，请用微信扫码登录。"
          }
        },
        {
          tag: "action",
          actions: [
            {
              tag: "button",
              text: { tag: "plain_text", content: "我要登录" },
              type: "primary",
              value: { action: "weread_login" }
            }
          ]
        }
      ]
    }
  end

  def poll_login(uuid)
    deadline = Time.current + POLL_TIMEOUT

    loop do
      data = WereadApiClient.get_login_result(uuid)

      if data["vid"] && data["token"]
        username = WereadApiClient.save_login_result(data)
        Option.delete("weread_pending_login_uuid")
        FeishuNotifier.send_text("✅ 微信读书登录成功：#{username}")
        Rails.logger.info("[WereadLoginReminderJob] 登录成功：#{username}")
        return
      end

      break if Time.current > deadline
      sleep POLL_INTERVAL
    end

    Option.delete("weread_pending_login_uuid")
    FeishuNotifier.send_text("⏰ 微信读书二维码已过期，请前往 #{settings_anchor_url} 重新登录")
    Rails.logger.info("[WereadLoginReminderJob] 二维码过期，等待下次推送")
  rescue WereadApiClient::ApiError => e
    Rails.logger.error("[WereadLoginReminderJob] 轮询登录状态失败: #{e.message}")
  end

  def generate_qr_png(scan_url)
    RQRCode::QRCode.new(scan_url).as_png(size: 400, border_modules: 2).to_s
  end

  def login_prompt_text
    "微信读书账号已过期，请用微信扫描上方二维码完成登录。\n若无法扫码，请点击：#{settings_anchor_url}"
  end

  # 生成 settings 页面的绝对链接（带 #weread 锚点，直达微信读书 Tab）
  def settings_anchor_url
    host = ENV["APP_HOST"].presence || "localhost"
    if Rails.env.production?
      Rails.application.routes.url_helpers.admin_settings_url(host: host, protocol: "https", anchor: "weread")
    else
      Rails.application.routes.url_helpers.admin_settings_url(host: host, protocol: "http", port: 3000, anchor: "weread")
    end
  end
end
