require 'faraday'
require 'faraday/retry'

class WechatApiClient
  BASE_URL = "https://down.mptext.top"

  class ApiError < StandardError
  end

  class ApiKeyExpiredError < ApiError
  end

  class ApiRateLimitError < ApiError
  end

  def self.connection
    @connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :url_encoded
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
    response = connection.get('/api/public/v1/download', {
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
    body = response.body.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    case response.status
    when 200
      parsed_body = JSON.parse(body)
      ret = parsed_body.dig("base_resp", "ret")
      if ret.present? && ret != 0
        Rails.logger.warn("WeChat API returned error: #{parsed_body}")
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
    raise ApiError, "无效的 JSON 响应：#{e.message}"
  end

  def self.handle_download_response(response)
    body = response.body.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
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
