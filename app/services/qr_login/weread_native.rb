module QrLogin
  # 微信读书（直连 weread.qq.com）的扫码登录。
  #
  # 与 QrLogin::Weread（转发服务账号池）的差异：
  #   - 直连微信读书网页版，登录结果是一套 Cookie（wr_vid / wr_skey ...），
  #     单会话落到 Option.weread_native_session_started!（而非往账号池追加）。
  #   - 二维码是 confirm 链接文本，可本地渲染成 PNG（RQRCode）。
  #   - 轮询需带上登录过程中累积的 cookie jar，因此 handle 里 round-trip jar。
  class WereadNative < Base
    class << self
      def key
        "weread_native"
      end

      def label
        "微信读书(直连)"
      end

      def settings_anchor
        "weread_native"
      end

      # 仅在真的需要时提醒：配成 weread_native 或已有会话，且会话已失效
      def reminder_needed?
        return false unless Option.wechat_api_provider == "weread_native" || Option.weread_native_cookie.present?

        !WereadNativeApiClient.session_valid?
      end

      def start
        result = WereadNativeApiClient.request_qr_code
        {
          handle: { "uuid" => result[:uuid], "cookie_jar" => result[:cookie_jar] || {} },
          image_bytes: qr_png(result[:scan_url]),
          image_mime: "image/png"
        }
      end

      # timeout / allow_retry 仅为满足统一接口，微信读书这边由 Faraday 连接自行控制
      def poll(handle, timeout: nil, allow_retry: true)
        result = WereadNativeApiClient.check_qr_status(handle["uuid"], handle["cookie_jar"])
        status = result[:status].to_s.to_sym
        # 每次轮询都可能带回新的 Set-Cookie，必须回存，否则后续步骤会丢会话
        next_handle = handle.merge("cookie_jar" => result[:cookie_jar] || handle["cookie_jar"])

        {
          status: Base::STATUSES.include?(status) ? status : :waiting,
          message: result[:message].to_s,
          handle: next_handle,
          result: status == :success ? result : nil
        }
      rescue WereadNativeApiClient::ApiError => e
        { status: :error, message: e.message, handle: handle, result: nil }
      end

      # → 微信读书用户名 / 会话标识
      def save_success!(result)
        account_info = result[:account_info] || {}
        Option.weread_native_session_started!(
          cookie_jar: result[:cookie_jar] || {},
          account_info: account_info
        )
        account_info["name"].presence || account_info["vid"].presence || label
      end

      def card_prompt_text
        "微信读书（直连）的登录会话已失效（有效期#{Option.weread_native_session_ttl_label}）。" \
          "点击下方按钮，将私聊收到专属二维码，请用微信扫码登录。"
      end
    end
  end
end
