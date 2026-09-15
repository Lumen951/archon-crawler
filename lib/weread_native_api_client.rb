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
#   get_mp_info(url, ...)         → [{id, cover, name, intro, updateTime}]（直抓文章页，无需会话）
#   validate_key                  → bool
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

  # 直连微信读书的保守限流（30 次/60 秒）
  LIST_RATE_LIMITER = RateLimiter.new(30, 60)

  # 微信文章页（mp.weixin.qq.com）抓取专用连接：与微信读书接口无关，
  # 用于 get_mp_info（无需微信读书登录会话）
  MP_BASE_URL = "https://mp.weixin.qq.com"

  # get_mp_info 实测可用的 Windows Chrome UA（脚本 script/get_mp_info.rb 验证；
  # 非浏览器 UA 会被 302 到环境验证页）
  MP_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36".freeze

  # 微信文章页抓取的保守限流（10 次/60 秒）
  MP_PAGE_RATE_LIMITER = RateLimiter.new(10, 60)

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
    @connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :rate_limiter, LIST_RATE_LIMITER
      f.request :retry, max: 3, interval: 1, backoff_factor: 2,
                exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      f.options.timeout = 20
      f.options.open_timeout = 10
      f.adapter Faraday.default_adapter
    end
  end

  # 登录流程专用连接：不限流、不缓存（扫码状态需要较频繁轮询）
  def self.login_connection
    @login_connection ||= Faraday.new(url: BASE_URL) do |f|
      f.options.timeout = 20
      f.options.open_timeout = 10
      f.adapter Faraday.default_adapter
    end
  end

  # 微信文章页抓取连接（get_mp_info 用，直访 mp.weixin.qq.com，与微信读书会话无关）
  def self.mp_connection
    @mp_connection ||= Faraday.new(url: MP_BASE_URL) do |f|
      f.request :rate_limiter, MP_PAGE_RATE_LIMITER
      f.request :retry, max: 3, interval: 1, backoff_factor: 2,
                exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
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
    { "articles" => [map_cover(cover, review_id)] }
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
      "cover" => cover["cover"] || cover["picUrl"] || cover["coverUrl"] || "",
      "digest" => cover["digest"] || cover["abstract"] || "",
      "author_name" => cover["name"] || "",
      "create_time" => normalize_time_seconds(cover["time"] || cover["createTime"] || cover["publishTime"]),
    }
  end

  # ── Article Content ───────────────────────────────────

  # 下载微信读书正文（仅处理 weread.qq.com/web/mp/content?reviewId=xxx 链接）
  # @return [String] 清洗后的正文 HTML
  def self.download_content(url, format: "html", crawl_task: nil)
    review_id = extract_review_id(url)
    raise DownloadError, "无法从链接解析 reviewId: #{url}" if review_id.blank?

    cookie_header = build_cookie_header(load_session!)
    resp = connection.get("/web/mp/content", { reviewId: review_id }, base_headers(cookie_header))
    handle_session_error!(resp)
    raise DownloadError, "下载正文失败: HTTP #{resp.status}" unless resp.status == 200

    body = resp.body.to_s
    body = body.dup.force_encoding(Encoding::UTF_8) if body.encoding == Encoding::ASCII_8BIT

    inner = extract_element_html(body, "js_content")
    raise DownloadError, "正文为空（可能未登录或文章不可见）" if inner.blank?

    clean_content(inner)
  rescue SessionExpiredError, LoginRequiredError => e
    raise e
  rescue Faraday::Error => e
    raise DownloadError, "下载正文失败: #{e.message}"
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

  # ── MP Info Lookup ────────────────────────────────────

  # 通过微信文章 URL 解析公众号信息。
  # 与 WereadApiClient#get_mp_info（转发服务 wxs2mp）不同：直接抓取文章页
  # HTML 提取（script/get_mp_info.rb 验证过的做法），无需微信读书登录会话。
  # 文章页的 __biz base64 解码即账号数字 id（见 normalize_book_id），
  # 由此拼出微信读书 book_id（MP_WXS_<数字>），保证与转发服务返回的 id 同构。
  # 文章页没有公众号简介，intro 恒为空串。
  # @param url [String] 微信公众号文章链接
  # @return [Array<Hash>] [{id, cover, name, intro, updateTime}]
  def self.get_mp_info(url, crawl_task: nil)
    url = url.to_s.strip.gsub("&amp;", "&")
    raise ApiError, "无效的微信公众号文章链接" unless url.include?("mp.weixin.qq.com")

    log(crawl_task, :debug, "get_mp_info: #{url[0..60]}...")

    html = fetch_mp_page(url)
    check_mp_page_error!(html)

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
  rescue Faraday::Error => e
    raise ApiError, "获取公众号信息失败: #{e.message}"
  end

  # 抓取文章页 HTML（桌面 Chrome UA + 手动跟随重定向）
  def self.fetch_mp_page(url)
    headers = {
      "User-Agent" => MP_UA,
      "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
      "Accept-Language" => "zh-CN,zh;q=0.9,en;q=0.8",
    }

    resp = mp_connection.get(url, {}, headers)
    3.times do
      break unless [ 301, 302 ].include?(resp.status)
      location = resp.headers["Location"].to_s
      break if location.blank?
      location = "#{MP_BASE_URL}#{location}" if location.start_with?("/")
      resp = mp_connection.get(location, {}, headers)
    end
    raise ApiError, "获取文章页失败: HTTP #{resp.status}" unless resp.status == 200

    body = resp.body.to_s
    body = body.dup.force_encoding(Encoding::UTF_8) if body.encoding == Encoding::ASCII_8BIT
    body
  end

  # 文章页反爬/状态检查（对齐 script/get_mp_info.rb 与 WechatCrawler.check_content_error）
  def self.check_mp_page_error!(html)
    if html.include?("当前环境异常") || html.include?("secitptpage/verify.html") ||
         html.include?("该内容已被发布者删除")
      raise ApiError, "微信文章页无法访问（环境验证/内容已删除），无法解析公众号信息"
    end
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
