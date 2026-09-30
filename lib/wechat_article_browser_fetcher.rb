require "cgi"
require "uri"
require "ferrum"

# 通过真实 Chromium 抓取微信公众号文章页正文。
#
# 背景：mp.weixin.qq.com 对部分文章强制「当前环境异常，需要验证」
# （wappoc_appmsgcaptcha），纯 HTTP 下载（WechatCrawler.fetch_article_page）
# 无法通过。微信的环境验证以 Cookie 形式留在浏览器里，因此这里的思路是：
#
#   1. 复用远程登录的浏览器环境——用户在设置页「远程浏览器登录」里完成的
#      人工验证/登录优先直接继承：登录浏览器仍在运行（含 Rails.cache 过期
#      但进程存活的孤儿）时附着开新标签页；
#   2. 否则用常驻共享浏览器（SharedBrowser）抓取：独立 user-data-dir，从
#      Session#frame 持续导出的 Cookie 快照回灌（会话级 Cookie 如环境验证、
#      slave_sid 不会被 Chrome 写进 profile，不回灌就继承不到人工验证成果），
#      每次抓取前重灌，无需每次重新验证。
#
# 抓取是串行的（类级 Mutex），且与 HTTP 路径共用同一个下载限流器。失败语义
# 与 HTTP 路径对齐：内容被删除等 → WechatCrawler::DownloadError（单篇失败）；
# 环境验证仍未通过 → CaptchaRequiredError（消息保留「当前环境异常，需要验证」
# 字样，download_article_content 依赖它终止整批下载）。
class WechatArticleBrowserFetcher
  # go_to 返回后等待 JS 渲染的时间。#js_content 是服务端渲染的，这里只是
  # 留给页内脚本的缓冲。
  LOAD_SETTLE_SECONDS = 1.5
  PROFILE_PROVIDER = "wechat_mp"

  class Error < StandardError; end

  class CaptchaRequiredError < Error; end

  @mutex = Mutex.new

  class << self
    # @param url [String] 文章链接（/s/… 或被拦截后的 wappoc_appmsgcaptcha 链接，
    #   后者会自动取 target_url 参数作为真实文章地址）
    # @return [String] 渲染后的文章页完整 HTML（由调用方 clean_rich_media_content 提取正文）
    # @raise [CaptchaRequiredError] 浏览器里仍被环境验证拦截
    # @raise [WechatCrawler::DownloadError] 内容被删除/审核中等（与 HTTP 路径同语义）
    # @raise [Error] 浏览器启动/连接失败
    def fetch(url, crawl_task: nil)
      target = target_url_for(WechatCrawler.normalize_article_url(url))

      @mutex.synchronize do
        WechatCrawler.download_rate_limiter.wait
        session_record = BrowserLogin::Session.active_record(PROFILE_PROVIDER) ||
                         BrowserLogin::Session.orphan_record(PROFILE_PROVIDER)
        WechatCrawler.log(crawl_task, :info,
                          "HTTP 下载被环境验证拦截，改用真实浏览器抓取（#{mode_label(session_record)}）: #{target[0, 80]}")

        html = with_browser(session_record, crawl_task) do |page|
          page.go_to(target)
          sleep(LOAD_SETTLE_SECONDS)
          verify_page!(page, target)
          page.body.to_s
        end
        WechatCrawler.log(crawl_task, :info, "浏览器抓取正文成功（#{html.length} 字符）")
        html
      end
    end

    private

    def mode_label(session_record)
      session_record ? "附着登录浏览器" : "共享浏览器+Cookie快照"
    end

    # 文章 url 有时存成了被拦截后的验证页链接（wappoc_appmsgcaptcha?…&target_url=…），
    # 此时真实地址在 target_url 参数里。
    def target_url_for(url)
      return url unless url.include?("appmsgcaptcha")

      query = URI.parse(url).query.to_s
      CGI.parse(query).dig("target_url", 0).presence || url
    rescue StandardError
      url
    end

    # 有存活登录浏览器/孤儿浏览器 → 附着开新标签页；否则走常驻共享浏览器
    # （首用拉起、跨抓取复用、空闲回收，详见 SharedBrowser）。
    def with_browser(session_record, crawl_task, &block)
      if session_record
        attach_to_session(session_record, &block)
      else
        SharedBrowser.with_page(crawl_task, &block)
      end
    end

    def attach_to_session(session_record)
      browser = BrowserLogin::Launcher.attach(session_record["port"])
      begin
        page = browser.create_page
        BrowserLogin::Launcher.pin_viewport(page)
        begin
          yield page
        ensure
          quietly { page.close }
        end
      ensure
        # 附着模式下 quit 只断开 CDP 连接，不会杀掉登录浏览器进程
        quietly { browser.quit }
      end
    rescue Ferrum::Error, IOError => e
      raise Error, "附着登录浏览器失败：#{e.class}: #{e.message}"
    end

    def quietly
      yield
    rescue StandardError
      nil
    end

    # 与 HTTP 路径同一套错误检查（删除/审核中/环境验证……）。
    # 「当前环境异常」转成带操作指引的 CaptchaRequiredError；其余原样抛出。
    def verify_page!(page, target)
      if page.url.to_s.include?("appmsgcaptcha")
        raise captcha_error(target)
      end

      WechatCrawler.check_content_error(page.body.to_s)
    rescue WechatCrawler::DownloadError => e
      raise captcha_error(target) if e.message.include?("当前环境异常")

      raise
    end

    def captcha_error(target)
      CaptchaRequiredError.new(
        "当前环境异常，需要验证：浏览器内仍被微信拦截。请在设置页「远程浏览器登录」打开微信公众号登录浏览器，" \
        "把下面的链接粘贴到地址栏打开，在页面里完成环境验证（验证状态会保留在本机浏览器环境中），之后重试下载即可。链接：#{target}"
      )
    end
  end
end
