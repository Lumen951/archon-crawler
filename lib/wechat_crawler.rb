require "async"
require "async/semaphore"
require "base64"
require "cgi"
require "faraday"
require "faraday/retry"
require "rate_limiter"
require "rate_limiter_middleware"

# Crawls WeChat public accounts. Orchestration across accounts (concurrency,
# pausing, retry scheduling) is handled by CrawlOrchestrator; this class only
# knows how to crawl a single WeChat account's articles.
#
# Uses the API provider configured in Option.wechat_api_provider:
#   "mp_native"   (default) — WechatMpNativeApiClient (扫码登录 mp.weixin.qq.com)
#   "dajiala"               — DajialaApiClient (dajiala.com)
#   "profile_ext"           — ProfileExtApiClient (mitmproxy 凭证)
#   "weread"                — WereadApiClient (微信读书转发服务账号池)
#   "weread_native"         — WereadNativeApiClient (直连 weread.qq.com，扫码登录单会话)
class WechatCrawler < BaseCrawler
  CHROME_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/101.0.4951.64 Safari/537.36".freeze

  # 正文下载限流器: 请求数/窗口秒数由 Option 配置（默认 20 次/60 秒，保守避免触发 mp.weixin.qq.com 限流）。
  # 按当前 Option 值缓存——配置变更后返回新实例（滑动窗口随之重置），
  # download_connection 会检测到实例变化并重建连接（中间件在构建时持有 limiter 引用）。
  def self.download_rate_limiter
    config = [Option.wechat_download_rate_limit, Option.wechat_download_rate_window]
    if @download_rate_limiter.nil? || @rate_limit_config != config
      @rate_limit_config = config
      @download_rate_limiter = RateLimiter.new(*config)
    end
    @download_rate_limiter
  end

  class DownloadError < StandardError; end

  # ── Article Content Download ───────────────────────────

  def self.download_connection
    limiter = download_rate_limiter
    if @download_connection.nil? || @download_connection_limiter != limiter
      @download_connection_limiter = limiter
      @download_connection = Faraday.new do |f|
        f.request :rate_limiter, limiter
        f.request :retry, max: 3, interval: 1, backoff_factor: 2,
                  exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
        f.options.timeout = 15
        f.options.open_timeout = 10
        f.adapter Faraday.default_adapter
      end
    end
    @download_connection
  end

  # 抓取微信文章页原始 HTML: URL 归一化 → GET → 跟随重定向（最多 3 跳）→ 错误检查。
  # download_content（取正文）与 get_mp_info（解析公众号信息）共用。
  # @return [String] 文章页完整 HTML
  def self.fetch_article_page(url, crawl_task: nil)
    article_url = normalize_article_url(url)

    headers = {
      "User-Agent" => CHROME_UA,
      "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
      "Accept-Language" => "zh-CN,zh;q=0.9,en;q=0.8",
      "Cache-Control" => "no-cache",
      "Pragma" => "no-cache"
    }

    resp = download_connection.get(article_url, {}, headers)

    # 跟随重定向 (最多 3 跳)
    3.times do
      break unless [ 301, 302 ].include?(resp.status)
      location = resp.headers["Location"]
      break unless location

      location = "https://mp.weixin.qq.com#{location}" if location.start_with?("/")
      resp = download_connection.get(location, {}, headers)
    end

    raise DownloadError, "下载文章失败: HTTP #{resp.status}" unless resp.status == 200

    body = resp.body.to_s
    body = body.dup.force_encoding(Encoding::UTF_8) if body.encoding == Encoding::ASCII_8BIT

    check_content_error(body)
    body
  rescue Faraday::Error => e
    raise DownloadError, "下载文章失败: #{e.message}"
  end

  # 下载文章正文 (直接从 mp.weixin.qq.com，无需 API key)
  # @param url [String] 文章链接 (支持 /s/ID、/s?__biz=…、或纯 id 等任意格式)
  # @param crawl_task [CrawlTask] 用于日志
  # @return [String] 清洗后的 HTML 内容
  def self.download_content(url, crawl_task: nil)
    # 微信读书（直连）的正文链接走微信读书接口（需登录会话），其余直访 mp.weixin.qq.com
    if WereadNativeApiClient.weread_content_url?(url)
      return WereadNativeApiClient.download_content(url, crawl_task: crawl_task)
    end

    log(crawl_task, :debug, "下载文章: #{normalize_article_url(url)[0..80]}..., 速率限制: #{download_rate_limiter.remaining}/#{Option.wechat_download_rate_limit}")

    clean_rich_media_content(fetch_article_page(url))
  end

  # 将各种格式的微信文章链接统一为可直接请求的 URL
  def self.normalize_article_url(url)
    url = url.to_s.strip
    url = url.gsub("&amp;", "&").sub("http://", "https://")

    if url.include?("mp.weixin.qq.com/s")
      url.sub(/#.*/, "")
    elsif !url.start_with?("http")
      "https://mp.weixin.qq.com/s/#{url}"
    else
      url
    end
  end

  # 检查文章页是否返回了错误状态
  def self.check_content_error(body)
    if body.include?("当前环境异常") || body.include?("secitptpage/verify.html")
      raise DownloadError, "当前环境异常，需要验证"
    elsif body.include?("该内容已被发布者删除") || body.include?("The content has been deleted")
      raise DownloadError, "该内容已被发布者删除"
    elsif body.include?("内容审核中")
      raise DownloadError, "内容审核中"
    elsif body.include?("该内容暂时无法查看")
      raise DownloadError, "该内容暂时无法查看"
    elsif body.include?("违规无法查看")
      raise DownloadError, "违规无法查看"
    end
  end

  # 提取并清洗 rich_media_content 区域
  def self.clean_rich_media_content(html)
    return "" if html.blank?

    doc = Nokogiri::HTML(html)
    content_div = doc.at_css("#js_content") || doc.at_css(".rich_media_content") || doc.at_css("#js_article")

    content_html = if content_div
                     content_div.inner_html
    else
                     js_content_match = html.match(/<div[^>]*id="js_content"[^>]*>(.*?)<\/div>\s*<script/m)
                     js_content_match ? js_content_match[1] : html
    end

    # data-src → src (懒加载图片修复)
    content_html = content_html.gsub(/data-src="/, 'src="')

    # 移除 opacity: 0 和 visibility: hidden 内联样式
    content_html = content_html.gsub(/style="[^"]*opacity\s*:\s*0[^"]*"/, "")
    content_html = content_html.gsub(/style="[^"]*visibility\s*:\s*hidden[^"]*"/, "")

    # 移除 script 和 style 标签
    content_html = content_html.gsub(/<script[^>]*>.*?<\/script>/m, "")
    content_html = content_html.gsub(/<style[^>]*>.*?<\/style>/m, "")

    # 清理多余空行
    content_html = content_html.gsub(/\n\s*\n/, "\n").strip

    content_html
  end

  # ── MP Info Lookup ────────────────────────────────────

  # 通过微信文章 URL 解析公众号信息（直抓文章页，无需任何 API 会话）。
  # 文章页的 __biz base64 解码即账号数字 id（见 WereadNativeApiClient.normalize_book_id），
  # 由此拼出微信读书 book_id（MP_WXS_<数字>），保证与转发服务返回的 id 同构。
  # 文章页没有公众号简介，intro 恒为空串。
  # @param url [String] 微信公众号文章链接
  # @return [Array<Hash>] [{id, cover, name, intro, updateTime}]
  def self.get_mp_info(url, crawl_task: nil)
    url = url.to_s.strip.gsub("&amp;", "&")
    raise DownloadError, "无效的微信公众号文章链接" unless url.include?("mp.weixin.qq.com")

    log(crawl_task, :debug, "get_mp_info: #{url[0..60]}...")

    html = fetch_article_page(url)

    biz = extract_mp_biz(html)
    return [] if biz.blank?

    fakeid = Base64.decode64(biz).gsub(/[^0-9]/, "")
    return [] if fakeid.empty?

    [{
      "id" => "MP_WXS_#{fakeid}",
      "cover" => extract_mp_var(html, "ori_head_img_url").to_s,
      "name" => extract_mp_nickname(html).to_s,
      "intro" => "",
      "updateTime" => extract_mp_var(html, "create_time").to_i,
    }]
  end

  # 提取文章页 JS 变量（var xxx = "..." / htmlDecode("...") / "xxx" * 1 等形式）
  def self.extract_mp_var(html, var_name)
    patterns = [
      /var\s+#{Regexp.escape(var_name)}\s*=\s*htmlDecode\(["']([^"']*)["']\)/,
      /var\s+#{Regexp.escape(var_name)}\s*=\s*["']([^"']*)["']/,
      /var\s+#{Regexp.escape(var_name)}\s*=\s*["']?(\d+)/,
    ]
    patterns.each do |pattern|
      match = html.match(pattern)
      return CGI.unescapeHTML(match[1]) if match
    end
    nil
  end

  # 公众号名称（var nickname = htmlDecode("...") 为主，兜底宽松匹配）
  def self.extract_mp_nickname(html)
    extract_mp_var(html, "nickname") ||
      html[/nickname["']?\s*[:=]\s*["']([^"']+)["']/, 1]
  end

  # 提取 __biz（URL 参数形式，可能是 URL 编码的 %3D%3D 填充；
  # 排除 ${window.biz} 之类的 JS 模板占位符）
  def self.extract_mp_biz(html)
    biz = html[/__biz=([A-Za-z0-9%+\/=]+)/, 1]
    CGI.unescape(biz) if biz
  end

  # ── Logging ────────────────────────────────────────────

  def self.log(crawl_task, level, message)
    Rails.logger.send(level, "[WechatCrawler] #{message}")
    crawl_task&.log(level, "[WechatCrawler] #{message}")
  end

  # ── API client routing ─────────────────────────────────
  def self.api_client
    case Option.wechat_api_provider
    when "dajiala" then DajialaApiClient
    when "profile_ext" then ProfileExtApiClient
    when "weread" then WereadApiClient
    when "weread_native" then WereadNativeApiClient
    else WechatMpNativeApiClient
    end
  end

  def self.crawl_account(account, crawl_task, article_concurrency:, max_pages:)
    task_account = crawl_task.crawl_task_accounts.find_by(account: account)
    task_account&.mark_running!

    log(crawl_task, :info, "开始抓取微信帐号: #{account.nickname} (fakeid: #{account.fakeid})")
    dajiala = Option.wechat_api_provider == "dajiala"
    weread  = Option.wechat_api_provider == "weread"
    weread_native = Option.wechat_api_provider == "weread_native"

    # 解析抓取标识: weread 用 mpId（必要时自动解析），weread_native 由 fakeid 换算 MP_WXS_，
    # dajiala 用 nickname，其余用 fakeid
    identifier = if weread
                   resolve_weread_mp_id(account, crawl_task)
                 elsif weread_native
                   WereadNativeApiClient.normalize_book_id(account.weread_mp_id)
                 elsif dajiala
                   account.nickname
                 else
                   account.fakeid
                 end

    offset = dajiala ? "" : 0
    pages_crawled = 0

    loop do
      break if crawl_task.reload.paused? || crawl_task.reload.failed?
      break if crawl_task.error_threshold_exceeded?(account.class.name)

      if max_pages > 0 && pages_crawled >= max_pages
        log(crawl_task, :debug, "#{account.nickname}: 已达到最大页数限制（#{max_pages} 页）")
        break
      end

      response = Retryable.with_retry(
        crawl_task: crawl_task,
        context: "#{account.nickname}: 文章列表获取 (offset: #{offset})"
      ) do
        api_client.get_articles(identifier, begin_offset: offset, size: 20, crawl_task: crawl_task)
      end
      break unless response

      articles_data = response['articles'] || []

      if articles_data.empty?
        log(crawl_task, :debug, "#{account.nickname}: 已到达末尾")
        break
      end

      log(crawl_task, :info, "#{account.nickname}: 获取了 #{articles_data.size} 篇文章（第 #{pages_crawled + 1} 页）")

      articles_data.each do |article_data|
        break if crawl_task.reload.paused? || crawl_task.reload.failed?
        break if crawl_task.error_threshold_exceeded?(account.class.name)

        find_or_create_article(article_data, account, crawl_task)
      end

      # Advance pagination
      if dajiala
        break if response["dajiala_end"]
        offset = response["dajiala_offset"] || ""
        break if offset.blank?
      else
        offset += 20
      end

      # weread 不足一页即到末尾，避免多发一次请求
      break if weread && articles_data.size < 20

      # weread_native 只暴露最新一篇，取到即结束
      break if weread_native

      pages_crawled += 1
    end

    # 正文下载由 WechatContentDownloadJob 独立任务处理（每日运行）
    account.refresh_activity_counters!
    account.mark_crawled!
    task_account&.mark_completed!
    log(crawl_task, :info, "#{account.nickname}: 抓取完成")
  rescue StandardError => e
    task_account&.mark_failed!(e.message)
    crawl_task.increment_error_count!(account.class.name)
    log(crawl_task, :error, "#{account.nickname}: 抓取出错 - #{e.message}")
    log(crawl_task, :error, "#{account.nickname}: 异常 backtrace: #{e.backtrace&.first(5)&.join(' | ')}")

    if [
      WereadApiClient::NoAvailableAccountError,
      WereadNativeApiClient::LoginRequiredError,
      WereadNativeApiClient::SessionExpiredError,
    ].any? { |err| e.is_a?(err) }
      crawl_task.fail_platform!(account.class.name)
      log(crawl_task, :error, "#{account.nickname}: #{e.message}，已中断#{account.platform_name}平台剩余帐号抓取")
    end
  end

  # weread 需要 mpId（MP_WXS_xxx）；若非该格式则通过已有文章 URL 自动解析
  # （直抓微信文章页，不依赖转发服务账号池/会话）
  def self.resolve_weread_mp_id(account, crawl_task)
    mp_id = account.weread_mp_id
    return mp_id if mp_id.to_s.match?(/\AMP_WXS_/)

    article = account.articles.order(published_at: :desc).first
    unless article&.url.present?
      raise WereadApiClient::ApiError, "无法解析 WeRead mpId: 帐号 #{account.nickname} 没有文章，无法通过文章URL获取 mpId"
    end

    begin
      result = get_mp_info(article.url, crawl_task: crawl_task)
    rescue DownloadError => e
      raise WereadApiClient::ApiError, "解析 WeRead mpId 失败: #{e.message}"
    end

    if result.is_a?(Array) && result.any? && result.first["id"].present?
      new_mp_id = result.first["id"]
      account.metadata ||= {}
      account.metadata["weread_mp_id"] = new_mp_id
      account.save!
      log(crawl_task, :debug, "#{account.nickname}: 已通过文章URL解析到 WeRead mpId: #{new_mp_id}")
      new_mp_id
    else
      mp_id # 解析失败时退回原值（与原 WereadCrawler 行为一致）
    end
  end

  # 查找或创建文章（只落库元数据，不下载正文）:
  #   - 新建的文章
  #   - 已存在但正文缺失的文章（上次下载失败）→ 关联到当前任务，供全局下载阶段重试
  # 已存在且正文完整时跳过。
  # @return [Article, nil] 需要下载正文的文章；无需下载时返回 nil
  def self.find_or_create_article(article_data, account, crawl_task)
    return if article_data['link'].blank?

    existing = Article.find_by(url: article_data['link'])
    if existing
      if existing.content_html.nil?
        # 关联到当前任务，供全局下载阶段统一抓取正文
        existing.update_column(:crawl_task_id, crawl_task.id) if existing.crawl_task_id != crawl_task.id
        log(crawl_task, :debug, "正文缺失，将重试下载: #{article_data['title']}")
        return existing
      else
        log(crawl_task, :debug, "跳过重复文章: #{article_data['title']}")
        return
      end
    end

    article = Article.create!(
      account: account,
      crawl_task: crawl_task,
      title: article_data['title'],
      url: article_data['link'],
      author: article_data['author_name'],
      digest: article_data['digest'],
      cover_url: article_data['cover'],
      published_at: Time.at(article_data['create_time'].to_i),
      raw_data: article_data
    )

    crawl_task.increment_progress!
    log(crawl_task, :debug, "已创建文章: #{article_data['title']}")
    article
  rescue ActiveRecord::RecordInvalid => e
    log(crawl_task, :debug, "跳过重复文章: #{article_data['link']}")
    nil
  rescue StandardError => e
    crawl_task.increment_error_count!(account.class.name)
    log(crawl_task, :error, "创建文章 #{article_data['link']} 失败: #{e.message}")
    nil
  end

  # 并发下载一批文章的正文，返回失败数量。单篇失败不会中断其他文章。
  # `on_article_complete` 每篇下载完成后调用（用于心跳/进度计数），不影响返回值语义。
  def self.download_article_contents(articles, crawl_task, semaphore, on_article_complete: nil)
    barrier = Async::Barrier.new

    articles.each do |article|
      barrier.async do
        semaphore.acquire do
          ok = download_article_content(article, crawl_task)
          on_article_complete&.call(article, ok)
          ok
        end
      end
    end

    failed = 0
    barrier.wait do |task|
      failed += 1 unless task.wait
    end
    failed
  end

  # 下载单篇文章正文并更新。正文下载有严格 rate limit，失败时保留文章元数据。
  # @return [Boolean] 是否成功下载
  def self.download_article_content(article, crawl_task)
    html_content = download_content(article.url, crawl_task: crawl_task)
    markdown_content = Html2Text.convert(html_content)

    article.update!(
      content_html: html_content,
      content_markdown: markdown_content
    )
    log(crawl_task, :debug, "已下载正文: #{article.title}")
    true
  rescue StandardError => e
    # 正文下载失败不算抓取失败: 文章元数据已落库，可稍后通过界面重新下载
    log(crawl_task, :warn, "下载正文失败 #{article.url}: #{e.message}")
    false
  end
end
