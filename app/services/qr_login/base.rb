require "base64"
require "rqrcode"
require "rqrcode_png"

module QrLogin
  # 扫码登录平台的抽象基类（全部是类方法，与项目里各 API Client 的风格一致）。
  #
  # 子类必须实现:
  #   key / label / start / poll / save_success!
  #
  # 统一的数据形状:
  #   start        → { handle:, image_bytes:, image_mime: }
  #   poll(handle) → { status:, message:, handle:（更新后，须回存）, result: }
  #   save_success!(result) → 身份字符串（账号名 / 公众号名），用于回执文案
  #
  # handle 必须是可序列化的普通 Hash（会存进 Rails.cache 跨请求复用）。
  class Base
    # 归一化后的扫码状态
    STATUSES = %i[waiting scanned success expired error].freeze

    class << self
      # ── 身份 ────────────────────────────────────────────

      def key
        raise NotImplementedError
      end

      def label
        raise NotImplementedError
      end

      # 设置页对应 Tab 的锚点（/admin/settings#<anchor>）
      def settings_anchor
        key
      end

      # 飞书卡片按钮的 action 值
      def card_action
        "#{key}_login"
      end

      # ── 流程 ────────────────────────────────────────────

      # 是否需要推送登录提醒。WeRead 恒为 true（持续扩充账号池），
      # 微信公众号平台仅在会话失效时为 true。
      def reminder_needed?
        true
      end

      # → { handle:, image_bytes:, image_mime: }
      def start
        raise NotImplementedError
      end

      # 单次轮询（不含循环，循环节奏由调用方决定，见 QrLogin::Polling）
      # → { status:, message:, handle:, result: }
      def poll(handle, timeout: nil, allow_retry: true)
        raise NotImplementedError
      end

      # 落库，返回身份字符串
      def save_success!(result)
        raise NotImplementedError
      end

      # ── 文案 ────────────────────────────────────────────

      def qr_prompt_text
        "#{label}需要扫码登录，请用微信扫描上方二维码完成登录。\n若无法扫码，请点击：#{settings_url}"
      end

      def expired_text
        "⏰ #{label}二维码已过期，请前往 #{settings_url} 重新登录"
      end

      def success_text(identity)
        "✅ #{label}登录成功：#{identity}"
      end

      def card_prompt_text
        "#{label}的登录已失效或需要扩充账号池。点击下方按钮，将私聊收到专属二维码，请用微信扫码登录。"
      end

      # 飞书交互卡片：点击按钮后由 FeishuCallbacksController 派发到本平台
      def card
        {
          config: { wide_screen_mode: true },
          header: {
            template: "blue",
            title: { tag: "plain_text", content: "#{label}账号登录" }
          },
          elements: [
            {
              tag: "div",
              text: { tag: "lark_md", content: card_prompt_text }
            },
            {
              tag: "action",
              actions: [
                {
                  tag: "button",
                  text: { tag: "plain_text", content: "我要登录" },
                  type: "primary",
                  value: { action: card_action }
                }
              ]
            }
          ]
        }
      end

      # 设置页绝对地址（带 Tab 锚点，飞书消息里点了直达）
      def settings_url
        host = ENV["APP_HOST"].presence || "localhost"
        options = { host: host, anchor: settings_anchor }
        options.merge!(Rails.env.production? ? { protocol: "https" } : { protocol: "http", port: 3000 })
        Rails.application.routes.url_helpers.admin_settings_url(**options)
      end

      # ── 工具 ────────────────────────────────────────────

      # 二维码直接内联到页面，避免依赖第三方二维码渲染服务
      def image_data_uri(image_bytes, image_mime = "image/png")
        "data:#{image_mime};base64,#{Base64.strict_encode64(image_bytes.to_s)}"
      end

      def qr_png(text)
        RQRCode::QRCode.new(text.to_s).as_png(size: 400, border_modules: 2).to_s
      end
    end
  end
end
