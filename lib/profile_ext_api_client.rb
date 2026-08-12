require 'faraday'
require 'faraday/retry'
require 'rate_limiter'
require 'rate_limiter_middleware'
require 'crawler_api_key_error'

# WeChat article API client using the mp/profile_ext endpoint directly.
# Requires credentials captured via mitmproxy (stored in Option.profile_ext_credentials).
#
# Provides the same public interface as WechatApiClient / DajialaApiClient:
#   get_articles(fakeid, ...) → { "articles" => [...] }
#   download_content(url, ...) → html string
#   validate_key → bool
class ProfileExtApiClient
  MP_HOST = 'mp.weixin.qq.com'
  BASE_URL = "https://#{MP_HOST}".freeze
  CREDENTIAL_LIVE_MINUTES = 25 # matches wechat-article-exporter config/index.ts
  USER_AGENT_MP = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36 WAE/1.0'.freeze
  USER_AGENT_WECHAT = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.34(0x16082222) NetType/WIFI Language/zh_CN'.freeze

  class ApiError < StandardError; end

  class CredentialExpiredError < ApiError
    include CrawlerApiKeyError
  end

  class CredentialMissingError < ApiError
    include CrawlerApiKeyError
  end

  # Rate limiter: 10 requests per minute (conservative for direct mp.weixin.qq.com access)
  RATE_LIMITER = RateLimiter.new(10, 60)

  # Download rate limiter: 5 requests per minute
  DOWNLOAD_RATE_LIMITER = RateLimiter.new(5, 60)

  def self.connection
    @connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :rate_limiter, RATE_LIMITER
      f.request :retry, max: 3, interval: 2, backoff_factor: 2,
                exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::ServerError]
      f.options.timeout = 15
      f.options.open_timeout = 10
      f.adapter Faraday.default_adapter
    end
  end

  def self.download_connection
    @download_connection ||= Faraday.new do |f|
      f.request :rate_limiter, DOWNLOAD_RATE_LIMITER
      f.request :retry, max: 2, interval: 1, backoff_factor: 2,
                exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      f.options.timeout = 15
      f.options.open_timeout = 10
      f.adapter Faraday.default_adapter
    end
  end

  # ── Logging ─────────────────────────────────────────────

  def self.log(crawl_task, level, message)
    Rails.logger.send(level, "[ProfileExt] #{message}")
    crawl_task&.log(level, "[ProfileExt] #{message}")
  end

  # ── Credential management ──────────────────────────────

  def self.credentials(fakeid = nil)
    raw = Option.profile_ext_credentials
    raise CredentialMissingError, '未配置 profile_ext 凭证' unless raw.present?

    parsed = JSON.parse(raw)
    entries = parsed.is_a?(Array) ? parsed : [parsed]

    return entries.first if fakeid.nil? && entries.any?

    # 按 __biz 匹配
    match = entries.find { |e| extract_biz(e) == fakeid }
    if match
      match
    elsif entries.any?
      # 没有匹配的，说明该号未抓包
      available = entries.map { |e| extract_biz(e) }.compact.join(', ')
      raise CredentialMissingError,
        "未找到 __biz=#{fakeid} 的凭证（当前凭证覆盖的号: #{available}）。" \
        "请在微信中打开该公众号的任意一篇文章以补抓凭证。"
    else
      raise CredentialMissingError, '凭证格式无效'
    end
  rescue JSON::ParserError => e
    raise CredentialMissingError, "凭证 JSON 解析失败: #{e.message}"
  end

  def self.extract_biz(entry)
    return nil unless entry.is_a?(Hash)
    url = entry['url'] || ''
    URI.decode_www_form(URI.parse(url).query.to_s).to_h['__biz']
  rescue StandardError
    nil
  end

  def self.credential_age_minutes(cred = nil)
    # 优先用 credentials.json 内部的 timestamp（毫秒），其次用 Option 存储时间
    cred ||= (credentials rescue nil)
    ts = cred&.dig('timestamp')
    if ts
      captured_at = Time.at(ts.to_f / 1000)
      return ((Time.current - captured_at) / 60.0).round(1)
    end

    updated_at = Option.profile_ext_credentials_updated_at
    return Float::INFINITY unless updated_at
    ((Time.current - Time.parse(updated_at)) / 60.0).round(1)
  end

  def self.credentials_valid?(cred = nil)
    return false unless Option.profile_ext_credentials.present?
    (cred || credentials rescue nil)  # no-op, just validate
    age = credential_age_minutes(cred)
    age < CREDENTIAL_LIVE_MINUTES
  rescue CredentialMissingError
    false
  rescue StandardError
    false
  end

  def self.all_account_bizs
    raw = Option.profile_ext_credentials
    return [] unless raw.present?
    parsed = JSON.parse(raw) rescue []
    entries = parsed.is_a?(Array) ? parsed : [parsed]
    entries.filter_map { |e| extract_biz(e) }
  end

  # ── Build cookie string from credentials ────────────────

  def self.build_cookie_string(cred)
    set_cookie = cred['set_cookie'] || ''
    set_cookie
      .split(',')
      .map { |p| p.strip.split(';').first }
      .filter_map { |nv| nv if nv&.include?('=') && !nv.include?('EXPIRED') }
      .reject { |nv| nv.split('=', 2).last.to_s.empty? }
      .join('; ')
  end

  # ── Extract params from credentials URL ─────────────────

  def self.extract_params(cred)
    url = cred['url'] || ''
    query = URI.parse(url).query.to_s
    URI.decode_www_form(query).to_h
  end

  # ── get_articles ────────────────────────────────────────

  def self.get_articles(fakeid, begin_offset: 0, size: 10, crawl_task: nil)
    cred = credentials(fakeid)

    unless credentials_valid?(cred)
      age = credential_age_minutes(cred)
      raise CredentialExpiredError, "profile_ext 凭证已过期 (#{age} 分钟前，有效期 #{CREDENTIAL_LIVE_MINUTES} 分钟)"
    end

    params = extract_params(cred)
    uin         = params['uin']
    key         = params['key']
    pass_ticket = params['pass_ticket']

    unless uin && key && pass_ticket
      raise CredentialMissingError, '凭证中缺少 uin/key/pass_ticket 参数'
    end

    cookie_str = build_cookie_string(cred)
    query = {
      'action'      => 'getmsg',
      '__biz'       => fakeid,
      'uin'         => uin,
      'key'         => key,
      'pass_ticket' => pass_ticket,
      'offset'      => begin_offset,
      'count'       => size,
      'f'           => 'json',
      'is_ok'       => '1',
      'scene'       => '124',
    }

    log(crawl_task, :debug, "profile_ext 请求: __biz=#{fakeid}, offset=#{begin_offset}, count=#{size}")
    log(crawl_task, :debug, "凭证 __biz=#{params['__biz']}, uin=#{uin[0..10]}..., cookie 字段=#{cookie_str.split(';').map { _1.split('=').first }.join(',')}")

    response = connection.get('/mp/profile_ext', query) do |req|
      req.headers['User-Agent'] = USER_AGENT_MP
      req.headers['Referer'] = BASE_URL + '/'
      req.headers['Cookie'] = cookie_str
    end

    log(crawl_task, :debug, "profile_ext 响应 HTTP #{response.status}, body=#{response.body.to_s[0..300]}")

    data = handle_response(response)

    ret = data['ret'] || data.dig('base_resp', 'ret')
    if ret != 0
      errmsg = data['errmsg'] || data.dig('base_resp', 'errmsg') || '未知错误'
      raise ApiError, "profile_ext 返回错误 (ret=#{ret}): #{errmsg}"
    end

    # Parse general_msg_list JSON string
    gml = data['general_msg_list']
    return { 'articles' => [] } unless gml.is_a?(String) && gml.present?

    parsed = JSON.parse(gml)
    items = parsed['list'] || []

    articles = items.flat_map do |item|
      ext = item['app_msg_ext_info']
      next [] unless ext

      main = article_from_ext(ext, item)
      subs = (ext['multi_app_msg_item_list'] || []).map { |s| article_from_ext(s, item) }
      [main] + subs
    end.compact

    { 'articles' => articles }
  rescue JSON::ParserError => e
    raise ApiError, "general_msg_list JSON 解析失败: #{e.message}"
  end

  def self.article_from_ext(ext, item)
    info = item['comm_msg_info'] || {}
    create_time = info['datetime'] || ext['create_time'] || 0

    {
      'link'        => (ext['content_url'] || '').gsub('&amp;', '&'),
      'title'       => ext['title'] || '',
      'author_name' => ext['author'] || '',
      'digest'      => ext['digest'] || '',
      'cover'       => ext['cover'] || '',
      'create_time' => create_time.to_i,
    }
  end

  # ── download_content ────────────────────────────────────

  def self.download_content(url, format: 'html', crawl_task: nil)
    url = url.to_s
      .gsub('&amp;', '&')
      .sub('http://', 'https://')
      .sub(/#.*/, '')

    log(crawl_task, :debug, "下载文章: #{url[0..100]}...")

    resp = download_connection.get(url) do |req|
      req.headers['User-Agent'] = USER_AGENT_WECHAT
    end

    # Follow redirect manually (Faraday auto-follows if we set it, but max 3 hops)
    if resp.status == 302 || resp.status == 301
      location = resp.headers['Location']
      return '' unless location
      if location.start_with?('/')
        location = "https://#{MP_HOST}#{location}"
      end
      return download_content(location, format: format)
    end

    raise ApiError, "下载失败 HTTP #{resp.status}" unless resp.status == 200

    body = resp.body.to_s
    if body.encoding == Encoding::ASCII_8BIT
      body = body.dup.force_encoding(Encoding::UTF_8)
    end
    body.encode('utf-8', invalid: :replace, undef: :replace)
  rescue Faraday::Error => e
    raise ApiError, "下载文章失败: #{e.message}"
  end

  # ── validate_key ────────────────────────────────────────

  def self.validate_key
    Option.profile_ext_credentials_valid?
  rescue StandardError
    false
  end

  # ── Response handling ───────────────────────────────────

  def self.handle_response(response)
    body = response.body.to_s
    if body.encoding == Encoding::ASCII_8BIT
      body = body.dup.force_encoding(Encoding::UTF_8)
    end

    case response.status
    when 200
      JSON.parse(body)
    when 302
      raise ApiError, 'profile_ext 返回重定向，凭证可能已过期'
    else
      raise ApiError, "profile_ext HTTP #{response.status}: #{body[0..200]}"
    end
  rescue JSON::ParserError => e
    raise ApiError, "profile_ext 响应 JSON 解析失败: #{e.message}"
  end
end
