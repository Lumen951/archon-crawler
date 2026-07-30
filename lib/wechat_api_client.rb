require 'faraday'
require 'faraday/retry'
require 'rate_limiter'
require 'rate_limiter_middleware'
require 'response_cache_middleware'

class WechatApiClient
  BASE_URL = "https://down.mptext.top"

  class ApiError < StandardError
  end

  class ApiKeyExpiredError < ApiError
    include CrawlerApiKeyError
  end

  class ApiRateLimitError < ApiError
  end

  RATE_LIMITER = RateLimiter.new(5, 60) # 20 requests per minute

  # Rate limiter for /api/public/v1/download — 1 requests per minute.
  # Shared across all instances; thread-safe and Async-fiber-safe.
  DOWNLOAD_RATE_LIMITER = RateLimiter.new(1, 60)

  def self.connection
    @connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :response_cache
      f.request :url_encoded
      f.request :rate_limiter, RATE_LIMITER
      f.request :retry, max: 3, interval: 1, backoff_factor: 2, exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      f.adapter Faraday.default_adapter
    end
  end

  # Separate connection for download endpoint — includes rate limiter middleware.
  def self.download_connection
    @download_connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :url_encoded
      f.request :rate_limiter, DOWNLOAD_RATE_LIMITER
      f.request :retry, max: 3, interval: 1, backoff_factor: 2, exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      f.adapter Faraday.default_adapter
    end
  end

  def self.headers
    api_key = Option.api_key
    raise ApiKeyExpiredError, "未配置 API 密钥" unless api_key

    {
      'X-Auth-Key' => api_key,
      'User-Agent' => 'MPCrawler/1.0'
    }
  end

  def self.search_account(keyword)
    response = connection.get('/api/public/v1/account', { keyword: keyword }, headers)
    handle_response(response)
  end

  def self.get_articles(fakeid, begin_offset: 0, size: 20)
    response = connection.get('/api/public/v1/article', {
      fakeid: fakeid,
      begin: begin_offset,
      size: size
    }, headers)

    handle_response(response)
  end

  def self.download_content(url, format: 'markdown')
    response = download_connection.get('/api/public/v1/download', {
      url: url,
      format: format
    }, headers)

    handle_download_response(response)
  end

  def self.validate_key
    response = connection.get('/api/public/v1/authkey', {}, headers)
    data = handle_response(response)
    Rails.logger.debug("WeChat API key validation response: #{data}")
    data['code'] == 0
  rescue ApiKeyExpiredError
    false
  end

  private

  def self.handle_response(response)
    body = response.body
    if body.encoding == Encoding::ASCII_8BIT
      body = body.dup.force_encoding(Encoding::UTF_8)
    end

    case response.status
    when 200
      parsed_body = JSON.parse(body)
      ret = parsed_body.dig("base_resp", "ret")
      if ret == 200013
        raise ApiRateLimitError, "频率限制（freq control）：#{response.status} - #{body}"
      elsif ret.present? && ret != 0
        raise ApiKeyExpiredError, "API 密钥已过期或无效：#{response.status} - #{body}"
      end
      parsed_body
    when 401
      raise ApiKeyExpiredError, "API 密钥已过期或无效：#{response.status} - #{body}"
    when 429
      raise ApiRateLimitError, "超出速率限制：#{response.status} - #{body}"
    else
      raise ApiError, "API 错误：#{response.status} - #{body}"
    end
  rescue JSON::ParserError => e
    raise ApiError, "无效的 JSON 响应：#{e.message} - #{body}"
  end

  def self.handle_download_response(response)
    body = response.body
    if body.encoding == Encoding::ASCII_8BIT
      body = body.dup.force_encoding(Encoding::UTF_8)
    end

    case response.status
    when 200
      body
    when 401
      raise ApiKeyExpiredError, "API 密钥已过期或无效：#{response.status} - #{body}"
    when 429
      raise ApiRateLimitError, "超出速率限制：#{response.status} - #{body}"
    else
      raise ApiError, "API 错误：#{response.status} - #{body}"
    end
  end
end
