module QrLogin
  # 微信读书（WeRead）转发服务的扫码登录。
  #
  # 传输层复用 WereadApiClient 的三个方法（MCP 工具与 rake 任务也直接用它们），
  # 这里只做「统一接口 + 状态归一化」。
  class Weread < Base
    # 转发服务只返回自由文本 message，靠关键词归类
    SCANNED_PATTERN = /扫描|已扫码|扫码成功|scan/i
    EXPIRED_PATTERN = /过期|失效|expired|超时/i
    ERROR_PATTERN = /WeReadError401/i

    class << self
      def key
        "weread"
      end

      def label
        "微信读书"
      end

      def settings_anchor
        "weread"
      end

      # 无条件推送：每日提醒的目的是持续扩充账号池，而不只是修复失效账号
      def reminder_needed?
        true
      end

      def start
        result = WereadApiClient.create_login_url
        uuid = result["uuid"]
        scan_url = result["scanUrl"]
        raise QrLogin::Error, "转发服务未返回二维码链接" if uuid.blank? || scan_url.blank?

        {
          handle: { "uuid" => uuid, "scan_url" => scan_url },
          image_bytes: qr_png(scan_url),
          image_mime: "image/png"
        }
      end

      def poll(handle, timeout: 120, allow_retry: true)
        data = WereadApiClient.get_login_result(handle["uuid"], timeout: timeout, allow_retry: allow_retry)

        if data["vid"].present? && data["token"].present?
          return { status: :success, message: "登录成功", handle: handle, result: data }
        end

        message = data["message"].to_s
        { status: normalize_status(message), message: message.presence || "等待扫码...", handle: handle, result: nil }
      rescue WereadApiClient::LoginPollTimeoutError => e
        { status: :waiting, message: "等待扫码...（状态查询暂时超时）", handle: handle, result: nil }
      rescue WereadApiClient::ApiError => e
        { status: :error, message: e.message, handle: handle, result: nil }
      end

      # → 微信读书用户名
      def save_success!(result)
        WereadApiClient.save_login_result(result)
      end

      def card_prompt_text
        "微信读书账号已过期或需要扩充账号池。点击下方按钮，将私聊收到专属二维码，请用微信扫码登录。"
      end

      private

      def normalize_status(message)
        return :error if message.match?(ERROR_PATTERN)
        return :expired if message.match?(EXPIRED_PATTERN)
        return :scanned if message.match?(SCANNED_PATTERN)

        :waiting
      end
    end
  end
end
