require 'faraday'
require 'faraday/retry'
require 'json'
require 'securerandom'
require 'rate_limiter'
require 'crawler_api_key_error'

# WeChat MP Native API Client — 纯 HTTP 方式直接访问 mp.weixin.qq.com
#
# 提供与 WechatApiClient / DajialaApiClient 相同的接口:
#   get_articles(fakeid, ...) → { "articles" => [...] }
#   download_content(url, ...) → html string
#   validate_key → bool
#
# 额外提供 QR 码登录功能:
#   request_qr_code → { qr_url:, uuid:, image_path: }
#   check_qr_status(uuid) → { status:, ... }
#
# 认证方式:
#   1. 通过 QR 码扫码登录获取 Cookie + Token
#   2. Cookie/Token 持久化在 Option 表中
#   3. 每次请求携带 Cookie 和 Token
#
# 文章列表: 多端点降级 (free_publish → publish → appmsgpublish → appmsg)
# 文章内容: 纯 HTTP GET + HTML 清洗
#
class WechatMpNativeApiClient
  BASE_URL = "https://mp.weixin.qq.com"

  USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36",
  ].freeze

  WECHAT_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.34(0x16082222) NetType/WIFI Language/zh_CN".freeze

  # Rate limiters for direct mp.weixin.qq.com access (conservative)
  LIST_RATE_LIMITER = RateLimiter.new(10, 60)     # 10 req/min for article list
  DOWNLOAD_RATE_LIMITER = RateLimiter.new(5, 60)  # 5 req/min for content download

  # ── Error classes ──────────────────────────────────────

  class ApiError < StandardError; end

  class SessionExpiredError < ApiError
    include CrawlerApiKeyError
  end

  class LoginRequiredError < ApiError
    include CrawlerApiKeyError
  end

  class RateLimitError < ApiError; end

  # ── Faraday connections ────────────────────────────────

  # Connection for login flow — uses a cookie jar to maintain session
  def self.login_connection
    @login_connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :url_encoded
      f.options.timeout = 15
      f.options.open_timeout = 10
      f.adapter Faraday.default_adapter
    end
  end

  # Connection for article list APIs — uses stored cookies
  def self.list_connection
    @list_connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :url_encoded
      f.request :retry, max: 3, interval: 1, backoff_factor: 2,
                exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      f.options.timeout = 15
      f.options.open_timeout = 10
      f.adapter Faraday.default_adapter
    end
  end

  # Connection for article content download — follows redirects
  def self.download_connection
    @download_connection ||= Faraday.new do |f|
      f.request :retry, max: 2, interval: 1, backoff_factor: 2,
                exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      f.options.timeout = 15
      f.options.open_timeout = 10
      f.adapter Faraday.default_adapter
    end
  end

  # ── Session helpers ────────────────────────────────────

  def self.cookie
    Option.wechat_mp_cookie
  end

  def self.token
    Option.wechat_mp_token
  end

  def self.session_valid?
    Option.wechat_mp_session_valid?
  end

  def self.load_session!
    raise LoginRequiredError, "未登录微信公众号平台，请先在设置中扫码登录" unless session_valid?
    [cookie, token]
  end

  # Build common request headers for MP API calls
  def self.build_mp_headers(referer = nil)
    cookie_str, token_str = load_session!
    {
      "User-Agent" => USER_AGENTS.sample,
      "Accept" => "application/json, text/plain, */*",
      "Accept-Language" => "zh-CN,zh;q=0.9,en;q=0.8",
      "Cookie" => cookie_str,
      "Referer" => referer || "#{BASE_URL}/cgi-bin/home?t=home/index&lang=zh_CN&token=#{token_str}",
    }
  end

  # ── QR Code Login ──────────────────────────────────────

  # Cookie jar for accumulating cookies during login flow
  @login_cookie_jar = {}

  class << self
    attr_accessor :login_cookie_jar
  end

  # Accumulate Set-Cookie from a Faraday response into the cookie jar
  def self.merge_response_cookies!(resp)
    set_cookie = resp.headers["set-cookie"]
    return unless set_cookie
    cookies = parse_set_cookie(set_cookie)
    @login_cookie_jar.merge!(cookies)
  end

  # Build a Cookie header string from the current cookie jar
  def self.build_cookie_header
    @login_cookie_jar.map { |k, v| "#{k}=#{v}" }.join("; ")
  end

  # Step 1: Request a QR code for login
  # Returns { qr_url:, uuid:, image_path:, cookie_jar: }
  def self.request_qr_code
    # Reset state
    @login_connection = nil
    @login_cookie_jar = {}

    conn = login_connection

    # Visit login page with browser-like headers to get proper cookies + QR info
    login_headers = {
      "User-Agent" => USER_AGENTS.first,
      "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language" => "zh-CN,zh;q=0.9,en;q=0.8",
    }

    resp = conn.get("/", {}, login_headers)
    raise ApiError, "访问登录页面失败: HTTP #{resp.status}" unless resp.status == 200
    merge_response_cookies!(resp)

    html = resp.body.to_s.force_encoding("UTF-8")

    # Log a snippet for debugging
    Rails.logger.info("[MP Native] Login page body length: #{html.length}, cookies so far: #{@login_cookie_jar.keys.join(', ')}")

    # Extract QR code URL and UUID from the login page
    # Pattern 1: Absolute URL in page source
    qr_url_match = html.match(%r{(https?://mp\.weixin\.qq\.com/cgi-bin/loginqrcode\?action=getqrcode&param=\d+)})
    # Pattern 2: UUID in JavaScript
    uuid_match = html.match(/(?:"|')uuid(?:"|')\s*:\s*(?:"|')([^"']+)(?:"|')/)

    if qr_url_match && uuid_match
      qr_url = qr_url_match[1]
      uuid = uuid_match[1]
      Rails.logger.info("[MP Native] Extracted QR URL and UUID from login page: uuid=#{uuid[0..8]}...")
    else
      # Fallback: use the API approach (startlogin → scanloginqrcode)
      Rails.logger.warn("[MP Native] Could not extract QR info from login page (qr_match=#{!!qr_url_match}, uuid_match=#{!!uuid_match}), using API approach...")
      Rails.logger.debug("[MP Native] HTML snippet: #{html[0..500]}")

      # Step 1: start_login — register UUID with the server
      uuid = SecureRandom.uuid.delete("-")
      @login_cookie_jar["uuid"] = uuid  # Set uuid cookie
      fingerprint = SecureRandom.uuid.delete("-")
      token_str = @login_cookie_jar["token"] || ""

      startlogin_url = "#{BASE_URL}/cgi-bin/bizlogin?action=startlogin"
      startlogin_data = {
        fingerprint: fingerprint,
        token: token_str,
        lang: "zh_CN",
        f: "json",
        ajax: "1",
        redirect_url: "/cgi-bin/settingpage?t=setting/index&action=index&token=#{token_str}&lang=zh_CN",
        login_type: "3",
      }

      startlogin_headers = {
        "User-Agent" => USER_AGENTS.first,
        "Accept" => "application/json, text/plain, */*",
        "Referer" => "#{BASE_URL}/",
        "Cookie" => build_cookie_header,
        "X-Requested-With" => "XMLHttpRequest",
      }

      begin
        start_resp = conn.post(startlogin_url, startlogin_data, startlogin_headers)
        merge_response_cookies!(start_resp)
        Rails.logger.info("[MP Native] startlogin response: HTTP #{start_resp.status}, body=#{start_resp.body.to_s[0..200]}")
        # Server may return uuid in response cookies
        server_uuid = @login_cookie_jar["uuid"]
        uuid = server_uuid if server_uuid.present?
      rescue StandardError => e
        Rails.logger.warn("[MP Native] startlogin failed: #{e.message}")
      end

      # Step 2: Request QR image from scanloginqrcode
      timestamp = (Time.now.to_f * 1000).to_i
      qr_url = "#{BASE_URL}/cgi-bin/scanloginqrcode?action=getqrcode&uuid=#{uuid}&random=#{timestamp}"
    end

    # Download QR code image with browser-like headers
    cookie_header = build_cookie_header
    qr_headers = {
      "User-Agent" => USER_AGENTS.first,
      "Accept" => "image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
      "Accept-Language" => "zh-CN,zh;q=0.9,en;q=0.8",
      "Cache-Control" => "no-cache",
      "Pragma" => "no-cache",
      "Sec-Fetch-Dest" => "image",
      "Sec-Fetch-Mode" => "no-cors",
      "Sec-Fetch-Site" => "same-origin",
      "Referer" => "#{BASE_URL}/",
      "Cookie" => cookie_header,
    }

    qr_image_resp = conn.get(qr_url, {}, qr_headers)
    Rails.logger.info("[MP Native] QR image response: HTTP #{qr_image_resp.status}, content-type=#{qr_image_resp.headers['content-type']}, body size=#{qr_image_resp.body.to_s.bytesize}")

    # Handle redirect (302) — follow to get actual image
    if [301, 302].include?(qr_image_resp.status)
      redirect_url = qr_image_resp.headers["Location"]
      Rails.logger.info("[MP Native] QR image redirect to: #{redirect_url}")
      if redirect_url.present?
        redirect_url = "#{BASE_URL}#{redirect_url}" if redirect_url.start_with?("/")
        qr_image_resp = conn.get(redirect_url, {}, qr_headers)
        Rails.logger.info("[MP Native] QR redirect response: HTTP #{qr_image_resp.status}, content-type=#{qr_image_resp.headers['content-type']}, body size=#{qr_image_resp.body.to_s.bytesize}")
      end
    end

    raise ApiError, "下载二维码失败: HTTP #{qr_image_resp.status}" unless qr_image_resp.status == 200
    merge_response_cookies!(qr_image_resp)

    # Verify the response is actually an image and detect format
    img_body = qr_image_resp.body.to_s
    content_type = qr_image_resp.headers['content-type'] || ''

    # Detect image format from magic bytes
    is_png  = img_body.start_with?("\x89PNG".b)
    is_jpg  = img_body.start_with?("\xFF\xD8\xFF".b)
    is_gif  = img_body.start_with?("GIF8".b)
    is_webp = img_body.start_with?("RIFF".b) && img_body[8..13] == "WEBP".b

    if img_body.bytesize < 100 || (!is_png && !is_jpg && !is_gif && !is_webp)
      Rails.logger.error("[MP Native] QR response is not a valid image. content-type=#{content_type}, body size=#{img_body.bytesize}. First 200 chars: #{img_body[0..200]}")
      raise ApiError, "二维码响应不是有效图片（可能是登录页面格式已变更，请检查日志）"
    end

    # Determine file extension
    ext = if is_png then "png"
          elsif is_jpg then "jpg"
          elsif is_gif then "gif"
          elsif is_webp then "webp"
          else "png"
          end

    # Save QR image to public directory
    qr_dir = Rails.root.join("public", "wechat_qr")
    FileUtils.mkdir_p(qr_dir)
    # Clean up old QR images for this UUID (any extension)
    Dir.glob(qr_dir.join("wx_qrcode_#{uuid}.*")).each { |f| File.delete(f) }
    image_path = qr_dir.join("wx_qrcode_#{uuid}.#{ext}")
    File.binwrite(image_path, img_body)

    Rails.logger.info("[MP Native] QR code saved: #{image_path} (#{img_body.bytesize} bytes, format=#{ext})")

    {
      qr_url: qr_url,
      uuid: uuid,
      image_path: "/wechat_qr/wx_qrcode_#{uuid}.#{ext}",
      cookie_jar: @login_cookie_jar.dup
    }
  rescue StandardError => e
    Rails.logger.error("[MP Native] request_qr_code error: #{e.message}")
    raise ApiError, "获取二维码失败: #{e.message}"
  end

  # Step 2: Check QR code scan status
  # Returns { status:, cookies:, token:, message: }
  # status: "waiting" | "scanned" | "success" | "expired" | "error"
  def self.check_qr_status(uuid, saved_cookie_jar = nil)
    conn = login_connection

    # Restore cookie jar from saved state
    @login_cookie_jar = (saved_cookie_jar || {}).dup

    cookie_header = build_cookie_header
    check_url = "#{BASE_URL}/cgi-bin/scanloginqrcode"
    params = {
      action: "ask",
      fingerprint: SecureRandom.uuid.delete("-"),
      lang: "zh_CN",
      f: "json",
      ajax: "1"
    }

    check_headers = {
      "User-Agent" => USER_AGENTS.first,
      "Accept" => "application/json, text/plain, */*",
      "Referer" => "#{BASE_URL}/",
      "Cookie" => cookie_header,
      "X-Requested-With" => "XMLHttpRequest",
    }

    resp = conn.get(check_url, params, check_headers)
    raise ApiError, "检查登录状态失败: HTTP #{resp.status}" unless resp.status == 200
    merge_response_cookies!(resp)

    data = begin
      JSON.parse(resp.body)
    rescue JSON::ParserError
      {}
    end

    status_code = data["status"] || 0
    # WeChat scanloginqrcode status codes (per mp.weixin.qq.com):
    #   0: waiting for scan
    #   1: user confirmed on phone → call bizlogin
    #   2, 3: QR expired / refreshed
    #   4: scanned, waiting for user to confirm on phone
    #   5: error (e.g. no email bound), should refresh QR
    #   6: confirming on phone (user tapped confirm, WeChat is processing)
    status = case status_code
             when 0 then "waiting"
             when 1 then "success"
             when 2, 3, 5 then "expired"
             when 4, 6 then "scanned"
             else "waiting"
             end

    result = { status: status, message: data["message"] || "" }

    if status == "success"
      redirect_url = data["userinfo"] || ""
      login_result = complete_login(conn, redirect_url)
      if login_result && login_result[:token].present? && login_result[:cookie_str].present?
        result[:cookies] = login_result[:cookies]
        result[:token] = login_result[:token]
        result[:cookie_str] = login_result[:cookie_str]
        result[:account_info] = login_result[:account_info]

        # Persist session
        Option.wechat_mp_cookie = result[:cookie_str]
        Option.wechat_mp_token = result[:token]
        Option.wechat_mp_login_state = "success"
        Option.wechat_mp_expires_at = (Time.current + 4.days).iso8601
        Option.wechat_mp_account_info = result[:account_info].to_json

        Rails.logger.info("[MP Native] Login successful, token=#{result[:token]&.slice(0, 8)}...")
      else
        reason = if login_result.nil?
                   "bizlogin 返回非 200"
                 elsif login_result[:token].blank?
                   "未能从 bizlogin 响应中提取 token"
                 else
                   "登录 cookie 为空"
                 end
        Rails.logger.warn("[MP Native] complete_login failed: #{reason}")
        result[:status] = "error"
        result[:message] = "登录确认成功但获取Token失败"
      end
    end

    result
  rescue StandardError => e
    Rails.logger.error("[MP Native] check_qr_status error: #{e.message}")
    { status: "error", message: e.message }
  end

  # Complete login after QR scan — call bizlogin?action=login
  def self.complete_login(conn, redirect_url = "")
    fingerprint = SecureRandom.uuid.delete("-")
    cookie_header = build_cookie_header

    login_data = {
      userlang: "zh_CN",
      redirect_url: redirect_url,
      cookie_forbidden: "0",
      cookie_cleaned: "0",
      plugin_used: "0",
      login_type: "3",
      fingerprint: fingerprint,
      token: "",
      lang: "zh_CN",
      f: "json",
      ajax: "1"
    }

    login_headers = {
      "User-Agent" => USER_AGENTS.first,
      "Accept" => "application/json, text/plain, */*",
      "Referer" => "#{BASE_URL}/",
      "Cookie" => cookie_header,
      "X-Requested-With" => "XMLHttpRequest",
    }

    resp = conn.post("#{BASE_URL}/cgi-bin/bizlogin?action=login", login_data, login_headers)
    return nil unless resp.status == 200
    merge_response_cookies!(resp)

    # Extract token from response or cookies
    token_match = resp.body.to_s.match(/token=([^&\s"']+)/)
    token = token_match ? token_match[1] : nil
    token ||= @login_cookie_jar["token"]

    # Build final cookie string
    cookie_str = build_cookie_header

    # Try to get account info
    account_info = {}
    begin
      home_headers = {
        "User-Agent" => USER_AGENTS.first,
        "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Cookie" => cookie_str,
      }
      home_resp = conn.get("#{BASE_URL}/cgi-bin/home?t=home/index&lang=zh_CN&token=#{token}", {}, home_headers)
      merge_response_cookies!(home_resp) if home_resp.status == 200
      name_match = home_resp.body.to_s.match(/nick_name\s*=\s*["']([^"']+)["']/)
      account_info[:nickname] = name_match[1] if name_match
    rescue StandardError => e
      Rails.logger.warn("[MP Native] Failed to get account info: #{e.message}")
    end

    # Update cookie string with any new cookies from home page
    cookie_str = build_cookie_header

    { cookies: @login_cookie_jar.dup, cookie_str: cookie_str, token: token, account_info: account_info }
  rescue StandardError => e
    Rails.logger.error("[MP Native] complete_login error: #{e.message}")
    nil
  end

  # ── Article List (Multi-endpoint fallback) ─────────────

  # Endpoint configurations, tried in priority order
  ENDPOINTS = [
    {
      name: "free_publish",
      path: "/cgi-bin/free_publish",
      params: ->(fakeid, token, begin_offset, count) {
        { action: "list", begin: begin_offset, count: count, fakeid: fakeid,
          token: token, lang: "zh_CN", f: "json", ajax: "1" }
      },
      list_key: "free_publish_list"
    },
    {
      name: "publish",
      path: "/cgi-bin/publish",
      params: ->(fakeid, token, begin_offset, count) {
        { action: "publish_list", begin: begin_offset, count: count, fakeid: fakeid,
          token: token, lang: "zh_CN", f: "json", ajax: "1" }
      },
      list_key: "publish_list"
    },
    {
      name: "appmsgpublish",
      path: "/cgi-bin/appmsgpublish",
      params: ->(fakeid, token, begin_offset, count) {
        { sub: "list", sub_action: "list_ex", begin: begin_offset, count: count,
          fakeid: fakeid, token: token, lang: "zh_CN", f: "json", ajax: "1" }
      },
      list_key: nil # data is in publish_page.publish_list
    },
    {
      name: "appmsg",
      path: "/cgi-bin/appmsg",
      params: ->(fakeid, token, begin_offset, count) {
        { action: "list_ex", begin: begin_offset, count: count, fakeid: fakeid,
          type: "9", token: token, lang: "zh_CN", f: "json", ajax: "1" }
      },
      list_key: "app_msg_list"
    }
  ].freeze

  # Discover which endpoint works for the current session
  def self.discover_endpoint(fakeid, crawl_task: nil)
    token_str = load_session![1]
    conn = list_connection

    ENDPOINTS.each do |ep|
      log(crawl_task, :debug, "尝试端点: #{ep[:name]}")
      begin
        params = ep[:params].call(fakeid, token_str, 0, 1) # Test with 1 item
        resp = conn.get(ep[:path], params, build_mp_headers)
        data = safe_json_parse(resp.body)

        ret = data.dig("base_resp", "ret") || -1
        next if ret == 200013 # Rate limited
        next if ret == 200003 # Session expired
        next if ret != 0

        if endpoint_has_data?(data, ep[:list_key])
          log(crawl_task, :info, "端点 #{ep[:name]} 可用!")
          return ep
        end
      rescue StandardError => e
        log(crawl_task, :debug, "端点 #{ep[:name]} 失败: #{e.message}")
      end
    end
    nil
  end

  # Check if endpoint response contains valid article data
  def self.endpoint_has_data?(data, list_key)
    if list_key && data[list_key].is_a?(Array) && data[list_key].any?
      return true
    end
    # appmsgpublish special case: publish_page contains publish_list
    if data["publish_page"].is_a?(String)
      begin
        pp = JSON.parse(data["publish_page"])
        return pp["publish_list"].is_a?(Array) && pp["publish_list"].any?
      rescue JSON::ParserError
        false
      end
    end
    false
  end

  # Main article list method — implements same interface as WechatApiClient
  def self.get_articles(fakeid, begin_offset: 0, size: 20, crawl_task: nil)
    load_session!
    token_str = token

    conn = list_connection
    LIST_RATE_LIMITER.wait

    # Try each endpoint until one works
    ENDPOINTS.each do |ep|
      log(crawl_task, :debug, "端点 #{ep[:name]}: fakeid=#{fakeid}, offset=#{begin_offset}, count=#{size}")
      begin
        params = ep[:params].call(fakeid, token_str, begin_offset, size)
        resp = conn.get(ep[:path], params, build_mp_headers)
        data = safe_json_parse(resp.body)

        ret = data.dig("base_resp", "ret")
        if ret == 200013
          raise RateLimitError, "频率限制 (freq control)"
        end
        if ret == 200003
          raise SessionExpiredError, "Session 已过期，请重新扫码登录"
        end
        if ret.present? && ret != 0
          err_msg = data.dig("base_resp", "err_msg") || "未知错误"
          log(crawl_task, :warn, "端点 #{ep[:name]} 返回错误 ret=#{ret}: #{err_msg}")
          next # Try next endpoint
        end

        articles = parse_articles(data, ep[:list_key])
        if articles.any?
          log(crawl_task, :debug, "端点 #{ep[:name]}: 获取到 #{articles.size} 篇文章")
          return { "articles" => articles }
        end
      rescue RateLimitError => e
        raise e
      rescue SessionExpiredError => e
        raise e
      rescue Faraday::Error => e
        log(crawl_task, :warn, "端点 #{ep[:name]} 请求失败: #{e.message}")
        next
      end
    end

    raise ApiError, "所有端点均无法获取文章列表，请检查登录状态"
  end

  # Parse articles from various response formats
  def self.parse_articles(data, list_key)
    articles = []

    # Format 1: Standard list key (free_publish_list, publish_list, app_msg_list)
    if list_key && data[list_key].is_a?(Array)
      data[list_key].each do |item|
        articles.concat(extract_articles_from_item(item))
      end
      return articles
    end

    # Format 2: appmsgpublish — publish_page.publish_list[].publish_info.appmsgex[]
    if data["publish_page"].is_a?(String)
      begin
        pp = JSON.parse(data["publish_page"])
        (pp["publish_list"] || []).each do |publish_item|
          pi = publish_item["publish_info"]
          pi = JSON.parse(pi) if pi.is_a?(String)
          next unless pi.is_a?(Hash) && pi["appmsgex"].is_a?(Array)

          pi["appmsgex"].each do |art|
            art["publish_info"] = pi
            articles << normalize_article(art)
          end
        end
      rescue JSON::ParserError
        # ignore
      end
    end

    articles
  end

  # Extract articles from a single item (may be a direct article or a publish container)
  def self.extract_articles_from_item(item)
    return [] unless item.is_a?(Hash)

    # Direct article
    if item["aid"].present? && item["title"].present?
      return [normalize_article(item)]
    end

    # Publish container: item.publish_info.appmsgex[]
    pi = item["publish_info"]
    pi = JSON.parse(pi) if pi.is_a?(String)
    if pi.is_a?(Hash) && pi["appmsgex"].is_a?(Array)
      return pi["appmsgex"].map { |art|
        art["publish_info"] = pi
        normalize_article(art)
      }
    end

    []
  end

  # Normalize article fields to the expected format
  def self.normalize_article(art)
    {
      "aid" => art["aid"],
      "title" => art["title"] || "",
      "link" => (art["link"] || art["content_url"] || "").gsub("&amp;", "&"),
      "cover" => art["cover"] || art["pic_cdn_url_1_1"] || art["cover_img_1_1"] || "",
      "digest" => art["digest"] || "",
      "author_name" => art["author_name"] || art["author"] || "",
      "create_time" => art["create_time"] || art["update_time"] || 0,
      "item_show_type" => art["item_show_type"] || 0,
      "copyright_stat" => art["copyright_stat"] || 0
    }
  end

  # ── Article Content Download ───────────────────────────

  def self.download_content(url, format: 'html', crawl_task: nil)
    DOWNLOAD_RATE_LIMITER.wait

    url = url.to_s
      .gsub("&amp;", "&")
      .sub("http://", "https://")
      .sub(/#.*/, "")

    log(crawl_task, :debug, "下载文章: #{url[0..100]}...")

    headers = {
      "User-Agent" => WECHAT_UA,
      "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language" => "zh-CN,zh;q=0.9",
    }

    resp = download_connection.get(url, {}, headers)

    # Follow redirect manually (up to 3 hops)
    3.times do
      break unless [301, 302].include?(resp.status)
      location = resp.headers["Location"]
      break unless location

      location = "https://mp.weixin.qq.com#{location}" if location.start_with?("/")
      resp = download_connection.get(location, {}, headers)
    end

    raise ApiError, "下载文章失败: HTTP #{resp.status}" unless resp.status == 200

    body = resp.body.to_s
    body = body.dup.force_encoding(Encoding::UTF_8) if body.encoding == Encoding::ASCII_8BIT
    body = body.encode("utf-8", invalid: :replace, undef: :replace)

    # Check for error states
    if body.include?("当前环境异常，完成验证后即可继续访问")
      raise ApiError, "当前环境异常，需要验证"
    elsif body.include?("该内容已被发布者删除") || body.include?("The content has been deleted")
      raise ApiError, "该内容已被发布者删除"
    elsif body.include?("内容审核中")
      raise ApiError, "内容审核中"
    elsif body.include?("该内容暂时无法查看")
      raise ApiError, "该内容暂时无法查看"
    elsif body.include?("违规无法查看")
      raise ApiError, "违规无法查看"
    end

    # Clean HTML content
    clean_html(body)
  rescue Faraday::Error => e
    raise ApiError, "下载文章失败: #{e.message}"
  end

  # ── HTML Cleaning ──────────────────────────────────────

  def self.clean_html(html)
    return "" if html.blank?

    # Extract #js_content
    content_match = html.match(/<div[^>]*id="js_content"[^>]*>(.*?)<\/div>\s*<script/m)
    content = if content_match
                content_match[1]
              else
                # Fallback: try #js_article
                article_match = html.match(/<div[^>]*id="js_article"[^>]*>(.*?)<\/div>\s*<script/m)
                article_match ? article_match[1] : html
              end

    # Fix lazy-loaded images: data-src → src
    content = content.gsub(/data-src="([^"]+)"/, 'src="\1"')

    # Remove common unwanted elements
    # Remove script tags
    content = content.gsub(/<script[^>]*>.*?<\/script>/m, "")
    # Remove style tags
    content = content.gsub(/<style[^>]*>.*?<\/style>/m, "")
    # Remove hidden elements
    content = content.gsub(/style="[^"]*display\s*:\s*none[^"]*"/, 'style="display:none"')

    # Clean empty lines
    content = content.gsub(/\n\s*\n/, "\n").strip

    content
  end

  # ── Session Validation ─────────────────────────────────

  def self.validate_session
    return false unless session_valid?

    begin
      token_str = token
      cookie_str = cookie
      return false if token_str.blank?

      conn = list_connection
      resp = conn.get(
        "#{BASE_URL}/cgi-bin/home",
        { t: "home/index", lang: "zh_CN", token: token_str },
        {
          "User-Agent" => USER_AGENTS.sample,
          "Cookie" => cookie_str,
        }
      )

      # Check if we're still on the home page (not redirected to login)
      resp.status == 200 && resp.env.url.to_s.include?("home")
    rescue StandardError => e
      Rails.logger.warn("[MP Native] Session validation error: #{e.message}")
      false
    end
  end

  def self.validate_key
    validate_session
  end

  def self.logout
    Option.wechat_mp_cookie = nil
    Option.wechat_mp_token = nil
    Option.wechat_mp_expires_at = nil
    Option.wechat_mp_login_state = nil
    Option.wechat_mp_account_info = nil

    # Clean up QR code images
    qr_dir = Rails.root.join("public", "wechat_qr")
    FileUtils.rm_rf(qr_dir) if Dir.exist?(qr_dir)

    @login_connection = nil
  end

  # ── Search Account ─────────────────────────────────────

  def self.search_account(keyword, limit: 10, offset: 0)
    load_session!
    token_str = token

    conn = list_connection
    params = {
      action: "search_biz",
      begin: offset,
      count: limit,
      query: keyword,
      token: token_str,
      lang: "zh_CN",
      f: "json",
      ajax: "1"
    }

    resp = conn.get("#{BASE_URL}/cgi-bin/searchbiz", params, build_mp_headers)
    data = safe_json_parse(resp.body)

    ret = data.dig("base_resp", "ret")
    raise SessionExpiredError, "Session 已过期请重新登录" if ret == 200003
    raise RateLimitError, "频率限制" if ret == 200013
    raise ApiError, "搜索失败: #{data.dig('base_resp', 'err_msg')}" if ret.present? && ret != 0

    list = data["list"] || []
    { "list" => list, "total" => data["total"] || list.size }
  end

  private

  # ── Cookie helpers ─────────────────────────────────────

  # Parse Set-Cookie header string(s) into a hash of name => value
  def self.parse_set_cookie(set_cookie)
    return {} if set_cookie.blank?

    result = {}
    # Handle both String and Array
    cookies = set_cookie.is_a?(Array) ? set_cookie : [set_cookie]

    cookies.each do |cookie_str|
      cookie_str.to_s.split(",").each do |part|
        part = part.strip
        next if part.blank?
        # Get the name=value pair (before the first ;)
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

  # ── JSON helpers ───────────────────────────────────────

  def self.safe_json_parse(body)
    body = body.dup.force_encoding(Encoding::UTF_8) if body.encoding == Encoding::ASCII_8BIT
    JSON.parse(body)
  rescue JSON::ParserError
    {}
  end

  # ── Logging ────────────────────────────────────────────

  def self.log(crawl_task, level, message)
    Rails.logger.send(level, "[MP Native] #{message}")
    crawl_task&.log(level, "[MP Native] #{message}")
  end
end
