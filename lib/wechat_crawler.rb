require "async"
require "async/semaphore"
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
#   "weread"                — WereadApiClient (微信读书转发)
class WechatCrawler < BaseCrawler
  CHROME_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/101.0.4951.64 Safari/537.36".freeze

  # 5 req/min — 保守设置，避免触发 mp.weixin.qq.com 限流
  DOWNLOAD_RATE_LIMITER = RateLimiter.new(5, 60)

  class DownloadError < StandardError; end

  # ── Article Content Download ───────────────────────────

  def self.download_connection
    @download_connection ||= Faraday.new do |f|
      f.request :rate_limiter, DOWNLOAD_RATE_LIMITER
      f.request :retry, max: 3, interval: 1, backoff_factor: 2,
                exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      f.options.timeout = 15
      f.options.open_timeout = 10
      f.adapter Faraday.default_adapter
    end
  end

  # 下载文章正文 (直接从 mp.weixin.qq.com，无需 API key)
  # @param url [String] 文章链接 (支持 /s/ID、/s?__biz=…、或纯 id 等任意格式)
  # @param crawl_task [CrawlTask] 用于日志
  # @return [String] 清洗后的 HTML 内容
  def self.download_content(url, crawl_task: nil)
    article_url = normalize_article_url(url)

    log(crawl_task, :debug, "下载文章: #{article_url[0..80]}...")

    if DOWNLOAD_RATE_LIMITER.remaining <= 0
      log(crawl_task, :debug, "速率限制等待中 (5 req/min)...")
    end
    DOWNLOAD_RATE_LIMITER.wait

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
    clean_rich_media_content(body)
  rescue Faraday::Error => e
    raise DownloadError, "下载文章失败: #{e.message}"
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
    if body.include?("当前环境异常，完成验证后即可继续访问")
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
    else WechatMpNativeApiClient
    end
  end
  def self.crawl_account(account, crawl_task, article_concurrency:, max_pages:)
    task_account = crawl_task.crawl_task_accounts.find_by(account: account)
    task_account&.mark_running!

    crawl_task.log(:info, "开始抓取帐号：#{account.nickname}")
    article_semaphore = Async::Semaphore.new(article_concurrency)

    dajiala = Option.wechat_api_provider == "dajiala"

    # Dajiala requires `alias` (ghid) instead of `fakeid`.
    # Search via mptext API to get account details and cache in metadata.
    # if dajiala
    #   if account.metadata&.dig('alias').blank?
    #     crawl_task.log(:info, "#{account.nickname}: 正在搜索公众号信息...")
    #     search_result = WechatApiClient.search_account(account.nickname)
    #     match = (search_result['list'] || []).find { |a| a['nickname'] == account.nickname }
    #     match ||= (search_result['list'] || []).first
    #     if match.blank?
    #       raise DajialaApiClient::ApiError, "无法找到帐号 #{account.nickname}，请检查帐号名称是否正确"
    #     end
    #     account.metadata = (account.metadata || {}).merge(match)
    #     account.save!
    #     crawl_task.log(:info, "#{account.nickname}: 已获取帐号信息，alias = #{match['alias']}")
    #   end
    # end

    # Dajiala uses alias (ghid), mptext uses fakeid
    # identifier = dajiala ? (account.metadata&.dig('alias').presence || account.fakeid) : account.fakeid
    identifier = dajiala ? account.nickname : account.fakeid
    offset = dajiala ? "" : 0
    pages_crawled = 0

    loop do
      break if crawl_task.reload.paused? || crawl_task.reload.failed?
      break if crawl_task.error_threshold_exceeded?(account.class.name)

      if max_pages > 0 && pages_crawled >= max_pages
        crawl_task.log(:info, "#{account.nickname}: 已达到最大页数限制（#{max_pages} 页）")
        break
      end

      response = Retryable.with_retry(
        crawl_task: crawl_task,
        context: "#{account.nickname}: 文章列表获取 (offset: #{offset})"
      ) do
        # mptext uses fakeid, Dajiala uses biz (stored in metadata)
        api_client.get_articles(identifier, begin_offset: offset, size: 20, crawl_task: crawl_task)
      end
      break unless response

      articles_data = response['articles'] || []

      if articles_data.empty?
        crawl_task.log(:info, "#{account.nickname}: 已到达末尾")
        break
      end

      crawl_task.log(:info, "#{account.nickname}: 获取了 #{articles_data.size} 篇文章（第 #{pages_crawled + 1} 页）")

      articles_data.each do |article_data|
        break if crawl_task.error_threshold_exceeded?(account.class.name)

        article_semaphore.async do
          fetch_and_save_article(article_data, account, crawl_task)
        end
      end

      # Advance pagination
      if dajiala
        break if response["dajiala_end"]
        offset = response["dajiala_offset"] || ""
        break if offset.blank?
      else
        offset += 20
      end

      pages_crawled += 1
      sleep 0.5
    end

    account.refresh_activity_counters!
    account.update_column(:last_crawled_at, Time.current)
    task_account&.mark_completed!
    crawl_task.log(:info, "#{account.nickname}: 抓取完成")
  rescue StandardError => e
    task_account&.mark_failed!(e.message)
    crawl_task.increment_error_count!(account.class.name)
    crawl_task.log(:error, "#{account.nickname}: 抓取出错 - #{e.message}")
    crawl_task.log(:error, "#{account.nickname}: 异常 backtrace: #{e.backtrace&.first(5)&.join(' | ')}")
    Rails.logger.error("Account #{account.fakeid} crawl error: #{e.message}")
  end

  def self.fetch_and_save_article(article_data, account, crawl_task)
    return if article_data['link'].blank?

    if Article.exists?(url: article_data['link'])
      crawl_task.log(:debug, "跳过重复文章：#{article_data['title']}")
      return
    end

    crawl_task.log(:debug, "正在下载内容：#{article_data['title']}")

    html_content = download_with_retry(article_data['link'], 'html', crawl_task)
    # markdown 格式仅限会员（请在请求头携带有效 X-Api-Token），游客仅支持 html 格式
    # markdown_content = download_with_retry(article_data['link'], 'markdown', crawl_task)
    markdown_content = Html2Text.convert(html_content)

    Article.create!(
      account: account,
      crawl_task: crawl_task,
      title: article_data['title'],
      url: article_data['link'],
      author: article_data['author_name'],
      digest: article_data['digest'],
      cover_url: article_data['cover'],
      content_markdown: markdown_content,
      content_html: html_content,
      published_at: Time.at(article_data['create_time'].to_i),
      raw_data: article_data
    )

    crawl_task.increment_progress!
    crawl_task.log(:info, "已保存文章：#{article_data['title']}")
  rescue ActiveRecord::RecordInvalid => e
    crawl_task.log(:debug, "跳过重复文章：#{article_data['link']}")
  rescue StandardError => e
    crawl_task.increment_error_count!(account.class.name)
    crawl_task.log(:error, "保存文章 #{article_data['link']} 失败：#{e.message}")
  end

  def self.download_with_retry(url, format, crawl_task)
    Retryable.with_retry(
      crawl_task: crawl_task,
      context: "下载 #{url} (#{format})"
    ) do
      download_content(url, crawl_task: crawl_task)
    end
  end
end
