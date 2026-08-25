require "faraday"
require "faraday/retry"
require "json"
require "rate_limiter"
require "rate_limiter_middleware"
require "response_cache_middleware"
require "crawler_api_key_error"

# WeChat article API client using the WeRead (微信读书) relay service.
#
# 提供与 WechatApiClient / DajialaApiClient 相同的接口:
#   get_articles(fakeid, ...) → { "articles" => [...] }
#   validate_key → bool
#
# 文章内容下载由 WechatCrawler.download_content 统一处理 (直接访问 mp.weixin.qq.com)。
#
# WeRead 账号管理:
#   - 存储在 Option.weread_accounts (JSON 数组 [{vid, token, name, status}])
#   - 随机选取账号实现负载均衡
#   - 每日黑名单机制: 429 限流的账号当天不再使用
#
class WereadApiClient
  PAGE_SIZE = 20

  # 微信浏览器 User-Agent
  WECHAT_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.34(0x16082222) NetType/WIFI Language/zh_CN".freeze

  # Rate limiters
  ARTICLE_LIST_RATE_LIMITER = RateLimiter.new(10, 60)  # 10 req/min for relay

  # ── Error classes ──────────────────────────────────────

  class ApiError < StandardError; end

  class WeReadAccountExpiredError < ApiError
    include CrawlerApiKeyError
  end

  class WeReadRateLimitError < ApiError; end
  class WeReadBadRequestError < ApiError; end
  class NoAvailableAccountError < ApiError; end

  # ── Faraday connections ────────────────────────────────

  # Connection to WeRead relay service for article lists
  def self.platform_connection
    @platform_connection ||= Faraday.new(url: platform_url) do |f|
      f.request :response_cache
      f.request :url_encoded
      f.request :rate_limiter, ARTICLE_LIST_RATE_LIMITER
      f.request :retry, max: 3, interval: 1, backoff_factor: 2,
                exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      f.options.timeout = 15
      f.options.open_timeout = 10
      f.adapter Faraday.default_adapter
    end
  end

  # 登录流程专用连接：不应用文章列表的 2 次/分钟限流，也不做响应缓存
  # （登录状态需要较频繁轮询，且不应缓存 "waiting" 结果）
  def self.login_connection
    @login_connection ||= Faraday.new(url: platform_url) do |f|
      f.request :url_encoded
      f.request :retry, max: 2, interval: 1, backoff_factor: 2,
                exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      f.options.timeout = 30
      f.options.open_timeout = 10
      f.adapter Faraday.default_adapter
    end
  end

  # 登录结果短轮询专用连接：无 retry，供 MCP 短超时轮询使用。
  # （带 retry 的连接在短超时时会把墙钟时间放大 retry 次数倍，不适合有界轮询）
  def self.login_poll_connection
    @login_poll_connection ||= Faraday.new(url: platform_url) do |f|
      f.request :url_encoded
      f.options.timeout = 5
      f.options.open_timeout = 5
      f.adapter Faraday.default_adapter
    end
  end

  # ── Platform URL ──────────────────────────────────────

  def self.platform_url
    Option.weread_platform_url
  end

  # ── Account pool management ────────────────────────────

  # 随机选取一个可用的 WeRead 账号
  def self.available_account
    accounts = enabled_accounts
    blocked = blocked_account_ids
    candidates = accounts.reject { |a| blocked.include?(a["vid"].to_s) }

    if candidates.empty?
      raise NoAvailableAccountError, "暂无可用微信读书账号!"
    end

    candidates.sample
  end

  # 所有 status=1 的账号
  def self.enabled_accounts
    Option.weread_accounts.select { |a| a["status"].to_i == 1 }
  end

  # 当日被限流的账号 vid 列表
  def self.blocked_account_ids
    blocks = Option.weread_blocked_accounts
    date_key = today_shanghai
    blocks[date_key] || []
  end

  # 将账号加入当日黑名单
  def self.block_account!(vid)
    blocks = Option.weread_blocked_accounts
    date_key = today_shanghai
    blocks[date_key] ||= []
    blocks[date_key] |= [vid.to_s]
    Option.weread_blocked_accounts = blocks
  end

  # 标记账号失效 (HTTP 401)
  def self.mark_account_invalid!(vid)
    accounts = Option.weread_accounts
    match = accounts.find { |a| a["vid"].to_s == vid.to_s }
    if match
      match["status"] = 0
      Option.weread_accounts = accounts
    end
    block_account!(vid)
  end

  # 从黑名单中移除账号 (账号更新/重新启用时)
  def self.remove_blocked_account(vid)
    blocks = Option.weread_blocked_accounts
    date_key = today_shanghai
    if blocks[date_key]
      blocks[date_key] = blocks[date_key].reject { |id| id == vid.to_s }
      Option.weread_blocked_accounts = blocks
    end
  end

  def self.today_shanghai
    Time.current.in_time_zone("Asia/Shanghai").to_date.to_s
  end

  # ── 错误拦截器 (mapping from wewe-rss trpc.service.ts lines 51-92) ──

  def self.handle_platform_error(response, request_vid)
    body = response.body.to_s

    if body.include?("WeReadError401")
      mark_account_invalid!(request_vid) if request_vid
      Rails.logger.error("[WeRead] 账号（#{request_vid}）登录失效，已禁用")
      raise WeReadAccountExpiredError, "微信读书账号登录失效"
    elsif body.include?("WeReadError429")
      block_account!(request_vid) if request_vid
      Rails.logger.error("[WeRead] 账号（#{request_vid}）请求频繁，打入小黑屋")
      raise WeReadRateLimitError, "微信读书请求频繁 (429)"
    elsif body.include?("WeReadError400")
      block_account!(request_vid) if request_vid
      Rails.logger.error("[WeRead] 账号（#{request_vid}）处理请求参数出错: #{body[0..200]}")
      sleep 10
      raise WeReadBadRequestError, "微信读书请求参数错误 (400)"
    else
      Rails.logger.error("[WeRead] 未处理的错误: #{body[0..200]}")
      raise ApiError, "微信读书API错误: #{body[0..200]}"
    end
  rescue WeReadAccountExpiredError, WeReadRateLimitError, WeReadBadRequestError => e
    raise e
  end

  # ── Article List ──────────────────────────────────────

  # 获取文章列表
  # @param fakeid [String] WeRead 的 mpId (如 MP_WXS_xxx)
  # @param begin_offset [Integer] 偏移量 (0, 20, 40...)
  # @param size [Integer] 每页数量
  # @param crawl_task [CrawlTask] 用于日志
  # @return [Hash] { "articles" => [{title, link, cover, create_time, ...}] }
  def self.get_articles(fakeid, begin_offset: 0, size: 20, page: nil, crawl_task: nil)
    account = available_account
    page ||= (begin_offset / size) + 1
    vid = account["vid"].to_s
    token = account["token"].to_s

    log(crawl_task, :debug, "get_articles: mpId=#{fakeid}, page=#{page}, account=#{vid}")

    resp = platform_connection.get(
      "/api/v2/platform/mps/#{fakeid}/articles",
      { page: page },
      {
        "xid" => vid,
        "Authorization" => "Bearer #{token}",
        "User-Agent" => "MPCrawler/1.0"
      }
    )

    unless resp.status == 200
      handle_platform_error(resp, vid)
    end

    log(crawl_task, :debug, "get_articles: HTTP #{resp.status}, body=#{resp.body[0..200]}")

    data = safe_json_parse(resp.body)

    # WeRead 返回格式: [{id, title, picUrl, publishTime}]
    articles = if data.is_a?(Array)
                 data
               elsif data.is_a?(Hash) && data["articles"].is_a?(Array)
                 data["articles"]
               else
                 []
               end

    log(crawl_task, :debug, "get_articles: 获取到 #{articles.size} 篇文章 (page=#{page})")

    # 映射到 mp-crawler 格式
    mapped = articles.map { |item| map_article(item) }

    { "articles" => mapped }
  rescue WeReadAccountExpiredError, WeReadRateLimitError, WeReadBadRequestError, NoAvailableAccountError => e
    raise e
  rescue Faraday::Error => e
    raise ApiError, "获取文章列表失败: #{e.message}"
  end

  # 将 WeRead 文章数据映射到 mp-crawler 的通用格式
  def self.map_article(item)
    article_id = item["id"].to_s
    {
      "id" => article_id,
      "title" => item["title"] || "",
      "link" => "https://mp.weixin.qq.com/s/#{article_id}",
      "cover" => item["picUrl"] || "",
      "create_time" => item["publishTime"].to_i,
      "author_name" => "",
      "digest" => "",
    }
  end

  # ── MP Info Lookup ────────────────────────────────────

  # 通过微信文章 URL 解析公众号信息
  # @param url [String] 微信公众号文章链接
  # @return [Array<Hash>] [{id, cover, name, intro, updateTime}]
  def self.get_mp_info(url, crawl_task: nil)
    url = url.to_s.strip
    account = available_account
    vid = account["vid"].to_s
    token = account["token"].to_s

    log(crawl_task, :debug, "get_mp_info: #{url[0..60]}...")

    resp = platform_connection.post(
      "/api/v2/platform/wxs2mp",
      { url: url }.to_json,
      {
        "xid" => vid,
        "Authorization" => "Bearer #{token}",
        "Content-Type" => "application/json",
        "User-Agent" => "MPCrawler/1.0"
      }
    )

    unless resp.status == 200
      handle_platform_error(resp, vid)
    end

    data = safe_json_parse(resp.body)
    data.is_a?(Array) ? data : []
  rescue WeReadAccountExpiredError, WeReadRateLimitError, NoAvailableAccountError => e
    raise e
  rescue Faraday::Error => e
    raise ApiError, "获取公众号信息失败: #{e.message}"
  end

  # ── Login Flow ─────────────────────────────────────────

  # 发起微信读书登录，获取二维码
  # @return [Hash] {uuid, scanUrl}
  def self.create_login_url
    resp = login_connection.get(
      "/api/v2/login/platform",
      {},
      { "User-Agent" => "MPCrawler/1.0" }
    )

    data = safe_json_parse(resp.body)
    {
      "uuid" => data["uuid"],
      "scanUrl" => data["scanUrl"]
    }
  rescue Faraday::Error => e
    raise ApiError, "获取登录二维码失败: #{e.message}"
  end

  # 轮询登录结果
  # @param uuid [String] 登录会话 ID
  # @param timeout [Numeric] 单次请求超时秒数（默认 120，转发服务会 long-poll）
  # @param allow_retry [Boolean] 是否使用带 retry 的连接（默认 true）。短轮询时应传 false
  #   （配合 login_poll_connection 使用，避免短超时 × retry 放大墙钟时间）
  # @return [Hash] {vid, token, username, message}
  def self.get_login_result(uuid, timeout: 120, allow_retry: true)
    conn = allow_retry ? login_connection : login_poll_connection
    resp = conn.get(
      "/api/v2/login/platform/#{uuid}",
      {},
      { "User-Agent" => "MPCrawler/1.0" }
    ) do |req|
      req.options.timeout = timeout
    end

    data = safe_json_parse(resp.body)
    data
  rescue Faraday::Error => e
    raise ApiError, "检查登录状态失败: #{e.message}"
  end

  # 保存登录结果到账号池（QrLogin::Weread / MCP 登录工具 / rake 任务共用）
  def self.save_login_result(data)
    vid = data["vid"].to_s
    token = data["token"].to_s
    username = data["username"].present? ? data["username"] : "wechat_user"

    accounts = Option.weread_accounts
    existing = accounts.find { |a| a["vid"].to_s == vid }

    if existing
      existing["token"] = token
      existing["name"] = username
      existing["status"] = 1
    else
      accounts << {
        "vid" => vid,
        "token" => token,
        "name" => username,
        "status" => 1
      }
    end

    Option.weread_accounts = accounts
    remove_blocked_account(vid)

    username
  end

  # ── Key Validation ─────────────────────────────────────

  # 真实调用 get_mp_info 测试 API gateway，而非仅检查账号池里是否有 status=1
  # 的账号。优先取库里最近一篇微信文章 URL（曾抓取成功，链接大概率仍有效）作为
  # 测试素材；库里还没有微信文章时退回到仅检查账号池（此时无法做真实网关测试）。
  def self.validate_key
    test_url = Article.joins(:account)
                      .where(accounts: { type: "WechatAccount" })
                      .where.not(url: nil)
                      .order(published_at: :desc)
                      .pick(:url)

    return Option.weread_accounts_valid? if test_url.blank?

    get_mp_info(test_url)
    true
  rescue NoAvailableAccountError, WeReadAccountExpiredError
    false
  end

  # ── Helpers ───────────────────────────────────────────

  def self.log(crawl_task, level, message)
    Rails.logger.send(level, "[WeRead] #{message}")
    crawl_task&.log(level, "[WeRead] #{message}")
  end

  def self.safe_json_parse(body)
    body = body.dup.force_encoding(Encoding::UTF_8) if body.encoding == Encoding::ASCII_8BIT
    JSON.parse(body)
  rescue JSON::ParserError
    {}
  end
end
