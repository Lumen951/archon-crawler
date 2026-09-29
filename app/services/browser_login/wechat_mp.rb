module BrowserLogin
  # 微信公众号平台（mp.weixin.qq.com）的远程浏览器登录。
  #
  # 与 QrLogin::WechatMp（纯 HTTP 轮询二维码）并存：HTTP 流程偶尔会因
  # 反爬/接口变动拿不到二维码，这时用真实浏览器登录是兜底手段。两者写入
  # 同一个会话槽位（Option.wechat_mp_session_started!），先成功者生效。
  class WechatMp < Base
    class << self
      def key
        "wechat_mp"
      end

      def label
        "微信公众号平台"
      end

      def login_url
        "https://mp.weixin.qq.com/"
      end

      def session_valid?
        Option.wechat_mp_session_valid?
      end

      # 微信的环境验证 Cookie 与登录态都在 qq.com 域，快照只保留该域
      def cookie_domain_pattern
        /qq\.com\z/
      end

      # 登录完成后微信会种下 slave_user / slave_sid 两个会话 Cookie
      def logged_in?(cookies)
        names = cookie_names(cookies, /qq\.com\z/)
        names.include?("slave_user") && names.include?("slave_sid")
      end

      # → 公众号名称
      def save!(page:, cookies:)
        token = extract_token(page)
        unless token
          # 登录后访问根路径会 302 到带 token 的 /cgi-bin/home
          page.go_to(login_url)
          token = extract_token(page)
        end
        raise Error, "登录成功但未能从页面提取 token，请停留在公众号首页后重试保存" unless token

        nickname = fetch_nickname(page)
        Option.wechat_mp_session_started!(
          cookie: cookie_string(cookies, /qq\.com\z/),
          token: token,
          account_info: { "nickname" => nickname }
        )
        nickname.presence || label
      end

      private

      def cookie_names(cookies, domain_pattern)
        cookies = cookies.values if cookies.is_a?(Hash)
        cookies.select { |c| c.domain.to_s =~ domain_pattern }.map(&:name)
      end

      # token 不在 Cookie 里，而是登录后跳转 URL / 页面表单中的参数
      def extract_token(page)
        page.url.to_s[/token=([^&\s"']+)/, 1] ||
          page.evaluate("document.documentElement.innerHTML")[/token=([^&\s"']+)/, 1]
      rescue StandardError
        nil
      end

      def fetch_nickname(page)
        page.evaluate(<<~JS).presence
          (() => {
            try {
              const viaCommonData = window.wx && window.wx.commonData
                && window.wx.commonData.data && window.wx.commonData.data.nickname;
              const viaDom = document.querySelector('.user_name')?.textContent
                || document.querySelector('.nickname')?.textContent;
              return String(viaCommonData || viaDom || '').trim();
            } catch (e) { return ''; }
          })()
        JS
      rescue StandardError
        ""
      end
    end
  end
end
