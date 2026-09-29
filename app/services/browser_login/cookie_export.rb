# 登录浏览器环境的 Cookie 快照（profile 目录内 cookies.json）。
#
# 为什么需要它：微信的环境验证 Cookie（wappoc）以及 slave_sid 等登录态往往是
# 会话级 Cookie（无过期时间），Chrome 不会把它们写进 profile 的 Cookies 库，
# 浏览器进程一退出就消失。于是「结束会话后拉起的一次性抓取浏览器」永远继承
# 不到人工验证/登录的成果，正文下载会再次被拦。
#
# 因此 Session#frame 在会话存续期间持续把 CDP 读到的 Cookie 序列化到 profile
# 目录；WechatArticleBrowserFetcher 等无会话消费者拉起独立浏览器后先回灌快照。
#
# 快照含登录凭据：与 Chrome profile 同目录（storage 卷内）、0600 权限、原子写，
# 只保留目标域的 Cookie；严禁输出到日志、测试输出或提交进版本库。
module BrowserLogin
  module CookieExport
    FILENAME = "cookies.json"

    class << self
      def path_for(profile_dir)
        Pathname.new(profile_dir).join(FILENAME)
      end

      # 序列化为可直接回灌 Ferrum::Cookies#set 的属性列表。
      # @param cookies [Array<Ferrum::Cookies::Cookie>] page.cookies.all.values
      # @param domain_pattern [Regexp, nil] 仅保留域名匹配的 Cookie（nil = 全保留）
      # @return [String] JSON 文本
      def serialize(cookies, domain_pattern: nil)
        JSON.generate(cookies.filter_map { |cookie| entry_for(cookie, domain_pattern) })
      end

      # 原子写入 profile 目录，返回写入条数
      def save(profile_dir, json)
        path = path_for(profile_dir)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp"
        File.write(tmp, json)
        File.rename(tmp, path)
        File.chmod(0600, path)
        JSON.parse(json).size
      end

      # 读取快照，返回可回灌的 Cookie 属性数组；缺失/损坏时返回 []（不致命）
      def load(profile_dir)
        path = path_for(profile_dir)
        return [] unless path.exist?

        JSON.parse(path.read).filter_map do |entry|
          next unless entry.is_a?(Hash)
          next unless entry["name"].present? && entry["value"].present? && entry["domain"].present?

          entry
        end
      rescue JSON::ParserError, StandardError => e
        Rails.logger.warn("[BrowserLogin] Cookie 快照读取失败: #{e.class}: #{e.message}")
        []
      end

      private

      # 转成 Network.setCookie 接受的最小属性集（剔除 size/session 等只读字段）
      def entry_for(cookie, domain_pattern)
        attrs = cookie.to_h
        return nil if domain_pattern && attrs["domain"].to_s !~ domain_pattern
        return nil if attrs["name"].blank? || attrs["value"].blank?

        entry = {
          "name" => attrs["name"], "value" => attrs["value"],
          "domain" => attrs["domain"], "path" => attrs["path"].presence || "/"
        }
        expires = attrs["expires"].to_f
        # 会话级 Cookie（expires=0）不带 expires 回灌，保持其会话语义
        entry["expires"] = expires.to_i if expires.positive?
        entry["httpOnly"] = attrs["httpOnly"] ? true : false
        entry["secure"] = attrs["secure"] ? true : false
        entry["sameSite"] = attrs["sameSite"] if %w[Strict Lax None].include?(attrs["sameSite"])
        entry
      end
    end
  end
end
