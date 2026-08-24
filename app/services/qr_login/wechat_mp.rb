module QrLogin
  # 微信公众号平台（mp.weixin.qq.com）的扫码登录。
  #
  # 与微信读书的差异：
  #   - 二维码是服务端渲染的图片字节（没有可独立扫描的文本链接，故无法渲染成终端 ASCII 码）
  #   - 轮询需要带上登录过程中累积的 cookie jar，因此 handle 里要把 jar 一起round-trip
  #   - 只有一个会话槽位（Option.wechat_mp_cookie/token），多人同时扫码时最后成功者胜出
  class WechatMp < Base
    class << self
      def key
        "wechat_mp"
      end

      def label
        "微信公众号平台"
      end

      def settings_anchor
        "mp_native"
      end

      # 仅在会话真的失效时提醒。validate_session 会实时探测 mp.weixin.qq.com，
      # 比 Option 里的 expires_at 时间戳更权威（微信可能提前作废会话）。
      #
      # 没配成 mp_native 且从未登录过时不提醒，避免对用不上的平台天天唠叨
      # （注意：即便抓取走别的 provider，帐号搜索仍依赖这个会话）。
      def reminder_needed?
        return false unless Option.wechat_api_provider == "mp_native" || Option.wechat_mp_cookie.present?

        !WechatMpNativeApiClient.validate_session
      end

      def start
        result = WechatMpNativeApiClient.request_qr_code
        {
          handle: { "uuid" => result[:uuid], "cookie_jar" => result[:cookie_jar] || {} },
          image_bytes: result[:image_bytes],
          image_mime: image_mime_for(result[:image_ext])
        }
      end

      # timeout / allow_retry 仅为满足统一接口，微信这边由 Faraday 连接自行控制
      def poll(handle, timeout: nil, allow_retry: true)
        result = WechatMpNativeApiClient.check_qr_status(handle["uuid"], handle["cookie_jar"])
        status = result[:status].to_s.to_sym
        # 每次轮询都可能带回新的 Set-Cookie，必须回存，否则后续步骤会丢会话
        next_handle = handle.merge("cookie_jar" => result[:cookie_jar] || handle["cookie_jar"])

        {
          # 常量要写全限定名：class << self 里的常量查找不会走到 Base 自身的常量表
          status: Base::STATUSES.include?(status) ? status : :waiting,
          message: result[:message].to_s,
          handle: next_handle,
          result: status == :success ? result : nil
        }
      rescue WechatMpNativeApiClient::ApiError => e
        { status: :error, message: e.message, handle: handle, result: nil }
      end

      # → 公众号名称
      def save_success!(result)
        account_info = result[:account_info] || {}
        Option.wechat_mp_session_started!(
          cookie: result[:cookie_str],
          token: result[:token],
          account_info: account_info
        )
        account_info[:nickname].presence || account_info["nickname"].presence || label
      end

      def card_prompt_text
        "微信公众号平台的登录会话已失效（有效期#{Option.wechat_mp_session_ttl_label}）。" \
          "点击下方按钮，将私聊收到专属二维码，请用微信扫码登录。"
      end

      private

      def image_mime_for(ext)
        case ext.to_s
        when "jpg", "jpeg" then "image/jpeg"
        when "gif" then "image/gif"
        when "webp" then "image/webp"
        else "image/png"
        end
      end
    end
  end
end
