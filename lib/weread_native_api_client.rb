require "faraday"
require "faraday/retry"
require "json"
require "cgi"
require "base64"
require "securerandom"
require "rate_limiter"
require "rate_limiter_middleware"
require "crawler_api_key_error"

# WeRead Native API Client — 直连 weread.qq.com（微信读书网页版），不经转发服务。
#
# 与 WereadApiClient（转发服务账号池）的区别：
#   - 通过扫码登录拿到一套 Cookie（wr_vid / wr_skey ...），单会话存在 Option 表里
#     （类似 WechatMpNativeApiClient 的 mp_native 会话），而非维护多账号池。
#   - 直接调用微信读书网页版接口。
#
# 提供与其它 API Client 相同的接口:
#   get_articles(identifier, ...) → { "articles" => [...] }
#   download_content(url, ...)    → html string（仅处理 weread.qq.com 正文链接）
#   validate_key                  → bool
#
# 文章元数据（发布时间 / 原始 mp.weixin.qq.com 链接）来自正文页内嵌的
# window.cgiDataNew —— /api/mp/cover 不返回发布时间，get_articles 会额外抓一次正文页。
#
# 公众号信息解析（get_mp_info，直抓文章页）已移至 WechatCrawler——它不依赖微信读书会话。
#
# 额外提供 QR 码登录功能（纯传输层，落库由 QrLogin::WereadNative 负责）:
#   request_qr_code                    → { uuid:, scan_url:, cookie_jar: }
#   check_qr_status(uuid, cookie_jar)  → { status:, cookie_jar:, cookie_str:, account_info: }
#
# 重要限制：微信读书网页版已下线历史文章列表接口（/web/mp/articles 恒返回 errCode -2041），
# 目前仅能通过 /api/mp/cover 拿到公众号「最新一篇」文章，正文经 /web/mp/content 提取
# #js_content 得到。因此每个公众号每次只会返回最新 1 篇文章。
class WereadNativeApiClient
  BASE_URL = "https://weread.qq.com"

  USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36".freeze

  # 直连微信读书的限流: 请求数/窗口秒数由 Option 配置（默认 30 次/60 秒）。
  # 按当前 Option 值缓存——配置变更后返回新实例（滑动窗口随之重置），
  # connection 会检测到实例变化并重建连接（中间件在构建时持有 limiter 引用）。
  def self.list_rate_limiter
    config = [Option.weread_native_list_rate_limit, Option.weread_native_list_rate_window]
    if @list_rate_limiter.nil? || @list_rate_config != config
      @list_rate_config = config
      @list_rate_limiter = RateLimiter.new(*config)
    end
    @list_rate_limiter
  end

  # ── Error classes ──────────────────────────────────────

  class ApiError < StandardError; end

  class SessionExpiredError < ApiError
    include CrawlerApiKeyError
  end

  class LoginRequiredError < ApiError
    include CrawlerApiKeyError
  end

  class DownloadError < ApiError; end

  # ── Faraday connections ────────────────────────────────

  # 文章列表 / 正文 / 订阅接口：带限流与重试
  def self.connection
    limiter = list_rate_limiter
    if @connection.nil? || @connection_limiter != limiter
      @connection_limiter = limiter
      @connection = Faraday.new(url: BASE_URL) do |f|
        f.request :rate_limiter, limiter
        f.request :retry, max: 3, interval: 1, backoff_factor: 2,
                  exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
        f.options.timeout = 20
        f.options.open_timeout = 10
        f.adapter Faraday.default_adapter
      end
    end
    @connection
  end

  # 登录流程专用连接：不限流、不缓存（扫码状态需要较频繁轮询）
  def self.login_connection
    @login_connection ||= Faraday.new(url: BASE_URL) do |f|
      f.options.timeout = 20
      f.options.open_timeout = 10
      f.adapter Faraday.default_adapter
    end
  end

  # ── Session helpers ────────────────────────────────────

  def self.cookie_jar
    Option.weread_native_cookie_jar
  end

  def self.session_valid?
    Option.weread_native_session_valid?
  end

  def self.load_session!
    raise LoginRequiredError, "未登录微信读书（直连），请先在设置中或通过飞书扫码登录" unless session_valid?
    cookie_jar
  end

  def self.base_headers(cookie_header = nil)
    {
      "User-Agent" => USER_AGENT,
      "Accept" => "application/json, text/plain, */*",
      "Referer" => "#{BASE_URL}/",
      "Origin" => BASE_URL,
    }.tap { |h| h["Cookie"] = cookie_header if cookie_header.present? }
  end

  # ── Article List ──────────────────────────────────────

  # 获取文章列表（微信读书只暴露最新一篇，故最多返回 1 篇；offset > 0 返回空）
  # @param identifier [String] MP_WXS_xxx 或公众号 fakeid（biz，会自动换算成 MP_WXS_）
  # @return [Hash] { "articles" => [{title, link, cover, create_time, ...}] }
  def self.get_articles(identifier, begin_offset: 0, size: 20, page: nil, crawl_task: nil)
    book_id = normalize_book_id(identifier)
    return { "articles" => [] } if begin_offset.to_i.positive? # 无历史列表，翻页即到末尾

    cookie_header = build_cookie_header(load_session!)
    ensure_subscribed(book_id, cookie_header, crawl_task)

    resp = connection.get("/api/mp/cover", { bookId: book_id }, base_headers(cookie_header))
    handle_session_error!(resp)

    cover = safe_json_parse(resp.body)
    unless cover.is_a?(Hash)
      raise ApiError, "获取最新文章失败: 响应格式异常"
    end

    err_code = cover["errCode"].to_i
    if err_code != 0 && cover.key?("errCode")
      raise ApiError, "微信读书 API 错误 #{err_code}: #{cover['errMsg'] || cover['errmsg']}"
    end

    review_id = cover["reviewId"].to_s
    return { "articles" => [] } if review_id.empty?

    log(crawl_task, :debug, "get_articles: #{book_id} 最新文章 reviewId=#{review_id}")
    article = map_cover(cover, review_id)
    merge_content_page_metadata!(article, review_id, crawl_task)
    { "articles" => [article] }
  rescue SessionExpiredError, LoginRequiredError => e
    raise e
  rescue Faraday::Error => e
    raise ApiError, "获取文章列表失败: #{e.message}"
  end

  # 微信读书按 book 订阅后才允许读取；未订阅先加入书架（否则 errCode -2041）
  def self.ensure_subscribed(book_id, cookie_header, crawl_task = nil)
    resp = connection.get("/web/shelf/bookIds", { bookIds: book_id }, base_headers(cookie_header))
    handle_session_error!(resp)
    data = safe_json_parse(resp.body)

    already = data.is_a?(Hash) && Array(data["bookIds"] || data["books"]).any? do |entry|
      (entry.is_a?(Hash) ? entry["bookId"] : entry).to_s == book_id
    end
    return if already

    log(crawl_task, :debug, "ensure_subscribed: 订阅 #{book_id}")
    add_resp = connection.post("/mp/shelf/addToShelf") do |req|
      base_headers(cookie_header).each { |k, v| req.headers[k] = v }
      req.headers["Content-Type"] = "application/json"
      req.body = { bookIds: [book_id] }.to_json
    end
    handle_session_error!(add_resp)
  rescue Faraday::Error => e
    log(crawl_task, :warn, "ensure_subscribed 失败（忽略，继续尝试读取）: #{e.message}")
  end

  # 把 /api/mp/cover 响应映射到 mp-crawler 通用文章格式
  def self.map_cover(cover, review_id)
    {
      "id" => review_id,
      "title" => cover["title"].to_s,
      # 优先用原始 mp.weixin.qq.com 链接（若响应带），否则用微信读书正文链接。
      # 正文下载会按链接域名分派（见 WechatCrawler.download_content）。
      "link" => extract_mp_url(cover) || weread_content_url(review_id),
      "cover" => cover["cover"] || cover["picUrl"] || cover["coverUrl"] || cover["pic"] || "",
      "digest" => cover["digest"] || cover["abstract"] || "",
      "author_name" => cover["name"] || "",
      "create_time" => normalize_time_seconds(cover["time"] || cover["createTime"] || cover["publishTime"]),
    }
  end

  # 用正文页内嵌的 window.cgiDataNew 元数据覆盖 cover 数据。
  # /api/mp/cover 不返回发布时间，原始 mp.weixin.qq.com 链接也只在正文页里有；
  # 抓一次正文页拿权威的 link / create_time / title / desc / cdn_url / nick_name。
  # 失败时退回 cover 数据（链接为微信读书正文页，create_time 为 0），不致命。
  def self.merge_content_page_metadata!(article, review_id, crawl_task)
    cgi = extract_cgi_data(fetch_content_page(review_id))

    if cgi["link"].present?
      # 保留微信读书链接供正文下载回退（WechatCrawler.download_content 按域名分派）
      article["weread_link"] = weread_content_url(review_id)
      article["link"] = cgi["link"]
    end
    article["create_time"] = parse_wechat_time(cgi["create_time"]) if cgi["create_time"].present?
    %w[title digest cover author_name].each do |key|
      article[key] = cgi[key] if cgi[key].present?
    end
    article
  rescue SessionExpiredError, LoginRequiredError => e
    raise e
  rescue ApiError => e
    log(crawl_task, :warn, "解析正文页元数据失败（退回 cover 数据）: #{e.message}")
    article
  end

  # ── Article Content ───────────────────────────────────

  # 下载微信读书正文（仅处理 weread.qq.com/web/mp/content?reviewId=xxx 链接）
  # @return [String] 清洗后的正文 HTML
  def self.download_content(url, format: "html", crawl_task: nil)
    review_id = extract_review_id(url)
    raise DownloadError, "无法从链接解析 reviewId: #{url}" if review_id.blank?

    body = fetch_content_page(review_id)
    inner = extract_element_html(body, "js_content")
    raise DownloadError, "正文为空（可能未登录或文章不可见）" if inner.blank?

    clean_content(inner)
  rescue SessionExpiredError, LoginRequiredError => e
    raise e
  rescue ApiError => e
    raise DownloadError, "下载正文失败: #{e.message}"
  end

  # 抓取微信读书正文页完整 HTML（元数据解析与正文下载共用）
  # @return [String] 页面原始 HTML
  def self.fetch_content_page(review_id)
    cookie_header = build_cookie_header(load_session!)
    resp = connection.get("/web/mp/content", { reviewId: review_id }, base_headers(cookie_header))
    handle_session_error!(resp)
    raise ApiError, "获取正文页失败: HTTP #{resp.status}" unless resp.status == 200

    body = resp.body.to_s
    body = body.dup.force_encoding(Encoding::UTF_8) if body.encoding == Encoding::ASCII_8BIT
    body
  rescue Faraday::Error => e
    raise ApiError, "获取正文页失败: #{e.message}"
  end

  # 解析正文页内嵌的 window.cgiDataNew（JS 对象字面量而非 JSON，按行首键名逐字段取值，
  # 避免被 content_noencode 大字符串干扰）。字符串为单引号 + \xNN / \' 转义。
  # @return [Hash] { "link", "create_time", "title", "digest", "cover", "author_name" }
  def self.extract_cgi_data(html)
    segment = html.to_s[/window\.cgiDataNew\s*=\s*\{.*/m]
    return {} unless segment

    {
      # link 里 & 被双重转义（\x26amp;），需 JS 反转义 + HTML 反转义
      "link" => unescape_html_entities(unescape_js_string(
        segment[/^[ \t]*link:\s*'(https:\/\/mp\.weixin\.qq\.com[^']*)'/, 1]
      )),
      "create_time" => segment[/^[ \t]*create_time:\s*'([^']*)'/, 1],
      "title" => unescape_js_string(segment[/^[ \t]*title:\s*'((?:\\.|[^'\\])*)'/, 1]),
      "digest" => unescape_js_string(segment[/^[ \t]*desc:\s*'((?:\\.|[^'\\])*)'/, 1]),
      "cover" => segment[/^[ \t]*cdn_url:\s*'([^']*)'/, 1],
      "author_name" => unescape_js_string(segment[/^[ \t]*nick_name:\s*'((?:\\.|[^'\\])*)'/, 1]),
    }.compact
  end

  # URL 里的 HTML 实体还原（&amp; → &）
  def self.unescape_html_entities(url)
    return nil if url.nil?

    CGI.unescapeHTML(url)
  end

  # JS 单引号字符串反转义：\xNN → 字符，\' / \" / \\ 还原
  def self.unescape_js_string(str)
    return nil if str.nil?

    str.gsub(/\\x([0-9a-fA-F]{2})/) { [$1.to_i(16)].pack("U") }
       .gsub("\\'", "'")
       .gsub('\\"', '"')
       .gsub("\\\\", "\\")
  end

  # 微信正文页的 create_time 形如 '2026-09-15 11:08'（北京时间）
  # @return [Integer, nil] Unix 时间戳（秒）
  def self.parse_wechat_time(str)
    return nil if str.blank?

    Time.find_zone("Asia/Shanghai").strptime(str.strip, "%Y-%m-%d %H:%M").to_i
  rescue ArgumentError
    nil
  end

  def self.weread_content_url?(url)
    url.to_s.include?("weread.qq.com/web/mp/content")
  end

  def self.weread_content_url(review_id)
    "#{BASE_URL}/web/mp/content?reviewId=#{CGI.escape(review_id.to_s)}"
  end

  def self.extract_review_id(url)
    return nil if url.blank?

    query = URI.parse(url.to_s).query rescue nil
    return CGI.parse(query.to_s)["reviewId"].first if query.present?
    nil
  rescue URI::InvalidURIError
    nil
  end

  # ── QR Code Login (transport only) ─────────────────────
  #
  # 微信读书网页版扫码登录：getuid → 展示 confirm 链接二维码 → 轮询 getinfo →
  # 确认后 weblogin + session/init 拿到完整 Cookie。
  # 登录过程中累积的 cookie 放在调用方持有的 jar 里逐层传递（不使用类级状态）。

  # Step 1: 申请登录 uid，返回可渲染成二维码的 confirm 链接
  # @return [Hash] { uuid:, scan_url:, cookie_jar: }
  def self.request_qr_code
    jar = {}
    resp = login_connection.post("/web/login/getuid") do |req|
      base_headers.each { |k, v| req.headers[k] = v }
      req.headers["Content-Type"] = "application/json"
      req.body = "{}"
    end
    merge_response_cookies!(jar, resp)

    data = safe_json_parse(resp.body)
    uid = data["uid"].to_s
    raise ApiError, "获取登录 uid 失败: #{data.inspect[0..200]}" if uid.empty?

    {
      uuid: uid,
      scan_url: "#{BASE_URL}/web/confirm?pf=2&uid=#{CGI.escape(uid)}",
      cookie_jar: jar,
    }
  rescue Faraday::Error => e
    raise ApiError, "获取二维码失败: #{e.message}"
  end

  # Step 2: 轮询扫码状态。纯传输层，不写 Option（落库由 QrLogin::WereadNative 负责）。
  # @return [Hash] { status:, message:, cookie_jar:（合并新 Set-Cookie 后，调用方须回存）,
  #                  cookie_str:, account_info: }
  #   status: "waiting" | "success" | "error"
  def self.check_qr_status(uuid, saved_cookie_jar = nil)
    jar = (saved_cookie_jar || {}).dup

    resp = login_connection.post("/web/login/getinfo") do |req|
      base_headers(build_cookie_header(jar)).each { |k, v| req.headers[k] = v }
      req.headers["Content-Type"] = "application/json"
      req.body = { uid: uuid }.to_json
    end
    merge_response_cookies!(jar, resp)

    login_info = safe_json_parse(resp.body)
    unless login_success?(login_info)
      return { status: "waiting", message: "等待扫码...", cookie_jar: jar }
    end

    # 确认成功：换取完整会话 Cookie
    weblogin(jar, login_info)
    session_init(jar, login_info)

    unless jar.key?("wr_skey") || jar.key?("wr_vid")
      return { status: "error", message: "登录确认成功但未取得会话 Cookie", cookie_jar: jar }
    end

    account_info = { "vid" => (login_info["vid"] || login_info.dig("login", "vid")).to_s }
    if (name = login_info.dig("userInfo", "name") || login_info.dig("user", "name")).present?
      account_info["name"] = name
    end

    {
      status: "success",
      message: "登录成功",
      cookie_jar: jar,
      cookie_str: build_cookie_header(jar),
      account_info: account_info,
    }
  rescue Faraday::Error => e
    { status: "error", message: "检查登录状态失败: #{e.message}", cookie_jar: jar }
  end

  # ── Key / Session Validation ───────────────────────────

  # 真实探测：用库里最近一篇微信文章对应公众号的 fakeid 拉一次最新文章，
  # 验证会话仍然可用。库里还没有微信文章时退回到仅检查会话字段是否齐全。
  def self.validate_key
    return false unless session_valid?

    fakeid = Article.joins(:account)
                    .where(accounts: { type: "WechatAccount" })
                    .where.not("accounts.fakeid" => nil)
                    .order(published_at: :desc)
                    .pick("accounts.fakeid")

    return true if fakeid.blank? # 无素材可测，仅凭会话字段判定

    get_articles(fakeid)
    true
  rescue SessionExpiredError, LoginRequiredError
    false
  rescue ApiError
    false
  end

  # ── Book ID resolution ────────────────────────────────

  # 把公众号标识归一化为微信读书 book_id（MP_WXS_<数字>）。
  # 微信文章的 biz（即 fakeid）是账号数字 id 的 base64，微信读书把每个公众号存成
  # id 为 MP_WXS_<该数字> 的 book，映射是确定的。
  def self.normalize_book_id(identifier)
    id = identifier.to_s.strip
    return id if id.start_with?("MP_WXS_")

    numeric = Base64.decode64(id).gsub(/[^0-9]/, "")
    raise ApiError, "无法从 fakeid 换算 MP_WXS_ id: #{identifier.inspect}" if numeric.empty?

    "MP_WXS_#{numeric}"
  end

  # ── Cookie helpers ────────────────────────────────────

  def self.merge_response_cookies!(jar, resp)
    jar.merge!(parse_set_cookie(resp.headers["set-cookie"]))
    jar
  end

  def self.build_cookie_header(jar)
    (jar || {}).map { |k, v| "#{k}=#{v}" }.join("; ")
  end

  def self.parse_set_cookie(set_cookie)
    return {} if set_cookie.blank?

    result = {}
    cookies = set_cookie.is_a?(Array) ? set_cookie : [set_cookie]
    cookies.each do |cookie_str|
      cookie_str.to_s.split(",").each do |part|
        part = part.strip
        next if part.blank?
        nv = part.split(";").first.to_s.strip
        next if nv.blank? || !nv.include?("=")
        name, value = nv.split("=", 2)
        next if value.to_s.empty?
        next if value.upcase.include?("EXPIRED")
        result[name.strip] = value.strip
      end
    end
    result
  end

  # ── Login sub-steps ───────────────────────────────────

  def self.weblogin(jar, login_info)
    resp = login_connection.post("/web/login/weblogin") do |req|
      base_headers(build_cookie_header(jar)).each { |k, v| req.headers[k] = v }
      req.headers["Content-Type"] = "application/json"
      req.body = login_info.to_json
    end
    merge_response_cookies!(jar, resp)
  rescue Faraday::Error => e
    Rails.logger.warn("[WeReadNative] weblogin 失败: #{e.message}")
  end

  def self.session_init(jar, login_info)
    resp = login_connection.post("/web/login/session/init") do |req|
      base_headers(build_cookie_header(jar)).each { |k, v| req.headers[k] = v }
      req.headers["Content-Type"] = "application/json"
      req.body = login_info.to_json
    end
    merge_response_cookies!(jar, resp)

    data = safe_json_parse(resp.body)
    cookie_data = data["cookies"] || data["cookie"]
    if cookie_data.is_a?(Hash)
      cookie_data.each { |name, value| jar[name.to_s] = value.to_s }
    end
  rescue Faraday::Error => e
    Rails.logger.warn("[WeReadNative] session/init 失败: #{e.message}")
  end

  def self.login_success?(data)
    return false unless data.is_a?(Hash)

    return true if data["user"]
    return true if data["userInfo"]
    return true if data["vid"]
    return true if data["wr_vid"]

    login = data["login"]
    login.is_a?(Hash) && (login["vid"] || login["userVid"] || login["user"])
  end

  # ── HTML extraction / cleaning ────────────────────────

  # 找到 <div id="...">...</div> 并返回其内层 HTML，用嵌套 <div> 深度计数避免提前截断
  def self.extract_element_html(html, element_id)
    opening = /<div\b[^>]*\bid=["']#{Regexp.escape(element_id)}["'][^>]*>/i.match(html)
    return nil unless opening

    pos = opening.end(0)
    depth = 1
    tag_re = /<div\b[^>]*>|<\/div>/i

    while depth.positive?
      tag = tag_re.match(html, pos)
      break unless tag

      depth += tag[0].start_with?("</") ? -1 : 1
      end_pos = tag.begin(0)
      pos = tag.end(0)

      return html[opening.end(0)...end_pos] if depth.zero?
    end

    nil
  end

  # 与 WechatCrawler.clean_rich_media_content 对齐的轻量清洗
  def self.clean_content(html)
    return "" if html.blank?

    html = html.gsub(/data-src="/, 'src="')
    html = html.gsub(/style="[^"]*opacity\s*:\s*0[^"]*"/, "")
    html = html.gsub(/style="[^"]*visibility\s*:\s*hidden[^"]*"/, "")
    html = html.gsub(/<script[^>]*>.*?<\/script>/m, "")
    html = html.gsub(/<style[^>]*>.*?<\/style>/m, "")
    html.gsub(/\n\s*\n/, "\n").strip
  end

  # ── Misc helpers ──────────────────────────────────────

  # cover 响应里可能藏着原始 mp.weixin.qq.com 链接，优先使用它以便与其它 provider 去重
  def self.extract_mp_url(cover)
    candidates = [cover["url"], cover.dig("mpInfo", "url"), cover.dig("review", "url"), cover["sourceUrl"]]
    candidates.compact.map(&:to_s).find { |u| u.include?("mp.weixin.qq.com") }
  end

  def self.normalize_time_seconds(value)
    n = value.to_i
    n > 2_000_000_000_000 ? n / 1000 : n
  end

  def self.handle_session_error!(resp)
    body = resp.body.to_s
    if resp.status == 401 || body.include?("WeReadError401") || body.include?("\"errCode\":-2012")
      raise SessionExpiredError, "微信读书（直连）会话失效，请重新扫码登录"
    end
  end

  def self.safe_json_parse(body)
    body = body.dup.force_encoding(Encoding::UTF_8) if body.encoding == Encoding::ASCII_8BIT
    JSON.parse(body)
  rescue JSON::ParserError
    {}
  end

  def self.log(crawl_task, level, message)
    Rails.logger.send(level, "[WeReadNative] #{message}")
    crawl_task&.log(level, "[WeReadNative] #{message}")
  end
end
