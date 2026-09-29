module BrowserLogin
  # 小红书网页版（xiaohongshu.com）的远程浏览器登录。
  #
  # 当前文章抓取走 RednoteApiClient / TikHub 付费 API，不依赖登录态；这里
  # 保存的 web_cookie 是为后续「免付费直连抓取」预留的凭据，也可用于排查
  # API 侧问题。登录方式：页面弹出的二维码用小红书 App 扫码。
  class RednoteWeb < Base
    # 小红书风控文案特征（实测页面原文含错误码 300012 与「IP 存在风险」）
    RISK_TEXT = /300012|IP\s*存在风险|切换到.{0,6}安全网络|当前环境异常/.freeze

    class << self
      def key
        "rednote_web"
      end

      def label
        "小红书（网页版）"
      end

      def login_url
        "https://www.xiaohongshu.com/"
      end

      def session_valid?
        Option.rednote_web_session_valid?
      end

      # 刻意不做自动判定：小红书对**匿名访客**也会下发 web_session
      # （2026-09 实测访客 jar: acw_tc/abRequestId/ets/webBuild/a1/webId/web_session...，
      # 访客 web_session 以 0300 开头），因此「有 web_session = 已登录」是错的，
      # 会导致把访客会话当登录态存下来。页面上也没有可靠的登录 DOM 信号
      # （访客的 window.__INITIAL_STATE__ 为空对象），所以这里不猜——
      # 由用户在扫码后显式点「保存登录态」确认。
      def logged_in?(_cookies)
        false
      end

      # 风控文案识别。小红书在 egress IP 被标记（机房 IP / VPN 出口）或浏览器
      # 指纹可疑时拒绝登录，页面出现「IP 存在风险…300012」之类文案。
      # UA 已在 Session 层归一化，这里的提示针对真实 IP 被标的场景。
      def risk_hint(page)
        text = page.evaluate("(document.body && document.body.innerText) || ''").to_s
        return nil unless text.match?(RISK_TEXT)

        "检测到小红书风控提示（IP 存在风险，错误码 300012）：请在下方「远程浏览器登录」设置中配置代理，" \
          "或更换服务器/本机网络后重试；打开「有界面模式」也能降低风控概率"
      rescue StandardError
        nil
      end

      # → 小红书昵称（取不到时返回平台名）
      def save!(page:, cookies:)
        nickname = fetch_nickname(page)
        Option.rednote_web_session_started!(
          cookie: cookie_string(cookies, cookie_domain_pattern),
          account_info: { "nickname" => nickname }
        )
        nickname.presence || label
      end

      def cookie_domain_pattern
        /xiaohongshu\.com\z/
      end

      private

      def fetch_nickname(page)
        raw = page.evaluate(<<~JS)
          (() => {
            try {
              const state = window.__INITIAL_STATE__;
              const user = state && state.user && state.user.currentUser;
              if (user && user.nickname) return user.nickname;
              const stored = localStorage.getItem('user_info') || localStorage.getItem('userData');
              if (stored) {
                const parsed = JSON.parse(stored);
                return parsed.nickname || parsed.name || '';
              }
              return '';
            } catch (e) { return ''; }
          })()
        JS
        raw.to_s.strip
      rescue StandardError
        ""
      end
    end
  end
end
