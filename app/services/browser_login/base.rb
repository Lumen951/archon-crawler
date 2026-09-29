module BrowserLogin
  # 各平台登录策略的统一接口（纯类方法，与 QrLogin::Base 风格一致）。
  #
  # 子类需要定义：
  #   key        - 平台标识（BrowserLogin::PROVIDERS 的键）
  #   label      - 中文显示名
  #   login_url  - 登录浏览器打开的起始页
  #   logged_in?(cookies) - 根据浏览器级 Cookie 判断是否已登录
  #   save!(page:, cookies:) - 把登录态写入 Option，返回身份文案
  #
  # cookies 是 Ferrum::Cookies::Cookie 数组（Network.getAllCookies，浏览器级）。
  class Base
    class << self
      def key = raise NotImplementedError

      def label = raise NotImplementedError

      def login_url = raise NotImplementedError

      # 默认按 Cookie 无法判断，子类按平台实现
      def logged_in?(_cookies)
        false
      end

      def save!(page:, cookies:)
        raise NotImplementedError
      end

      # 供设置页展示的静态会话状态（读 Option，不碰浏览器）
      def session_valid?
        false
      end

      # 登录页面出现平台风控文案时，返回给用户的可操作提示；默认无。
      # 检测在每次截图时进行，文案渲染在弹窗状态栏里。
      def risk_hint(_page)
        nil
      end

      private

      # 把浏览器 Cookie 过滤出目标域后拼成 "k=v; k2=v2" 头字符串。
      # 与 WechatMpNativeApiClient.build_cookie_header 的格式保持一致。
      def cookie_string(cookies, domain_pattern)
        cookies = cookies.values if cookies.is_a?(Hash)
        cookies.select { |c| c.domain.to_s =~ domain_pattern && c.value.present? }
               .map { |c| "#{c.name}=#{c.value}" }
               .join("; ")
      end

      # 同上，但产出 name => value 的 jar（weread_native 的存储格式）
      def cookie_jar(cookies, domain_pattern)
        cookies = cookies.values if cookies.is_a?(Hash)
        cookies.select { |c| c.domain.to_s =~ domain_pattern && c.value.present? }
               .each_with_object({}) { |c, jar| jar[c.name] = c.value }
      end
    end
  end
end
