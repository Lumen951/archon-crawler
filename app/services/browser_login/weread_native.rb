module BrowserLogin
  # 微信读书直连（weread.qq.com）的远程浏览器登录。
  #
  # 与 QrLogin::WereadNative（HTTP 轮询二维码 / 飞书推送）写入同一个会话
  # 槽位 Option.weread_native_session_started!。会话 TTL 只有 2 小时，
  # 好处是 profile 目录持久化 Cookie 后，重开浏览器多数时候免扫码。
  class WereadNative < Base
    class << self
      def key
        "weread_native"
      end

      def label
        "微信读书（直连）"
      end

      def login_url
        "https://weread.qq.com/#login"
      end

      def session_valid?
        Option.weread_native_session_valid?
      end

      # wr_vid 是用户标识，wr_skey 是会话密钥，两者齐备才算登录
      def logged_in?(cookies)
        jar = cookie_jar(cookies, /qq\.com\z/)
        jar["wr_vid"].present? && jar["wr_skey"].present?
      end

      # → 微信读书账号 vid
      def save!(page:, cookies:)
        jar = cookie_jar(cookies, /qq\.com\z/)
        account_info = { "vid" => jar["wr_vid"] }
        Option.weread_native_session_started!(cookie_jar: jar, account_info: account_info)
        jar["wr_vid"].present? ? "#{label} #{jar['wr_vid']}" : label
      end
    end
  end
end
