require "faraday"
require "faraday/retry"
require "response_cache_middleware"

class TikHubApiClient
  BASE_URL = "https://api.tikhub.io"

  class ApiError < StandardError
  end

  class ApiKeyMissingError < ApiError
    include CrawlerApiKeyError
  end

  class ApiRateLimitError < ApiError
  end

  def self.connection
    @connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :response_cache
      f.request :retry, max: 3, interval: 1, backoff_factor: 2,
                         exceptions: [ Faraday::TimeoutError, Faraday::ConnectionFailed ]
      f.adapter Faraday.default_adapter
    end
  end

  def self.headers
    key = Option.tikhub_api_key
    raise ApiKeyMissingError, "未配置 TikHub API 密钥（tikhub_api_key）" unless key.present?
    {
      "Authorization" => "Bearer #{key}",
      "Content-Type"  => "application/json"
    }
  end

  # Search Xiaohongshu users by keyword.
  # Returns the "data" portion of the response (containing "users" array, "search_id", etc.)
  #
  # Response example (GET /api/v1/xiaohongshu/app_v2/search_users?keyword=蔚来&page=1):
  #   {
  #     "success" => true,
  #     "code"    => 0,
  #     "data"    => {
  #       "users" => [
  #         {
  #           "id"         => "5663dbb17c5bb8369230f1b9",
  #           "name"       => "蔚来",
  #           "image"      => "https://sns-avatar-qc.xhscdn.com/avatar/...",
  #           "red_id"     => "49316315635",
  #           "desc"       => "汽车厂商",
  #           "sub_title"  => "Fans 182.5k",
  #           "red_official_verified" => true,
  #           ...
  #         },
  #         ...
  #       ],
  #       "filters"   => [...],
  #       "search_id" => "3a42ae1d5b524f2f"
  #     },
  #     "search_id"  => "3a42ae1d5b524f2f",
  #     "page"       => 1,
  #     "next_page"  => 2
  #   }
  #
  # Pagination: first request pass only keyword + page; subsequent pages pass search_id from first response.
  def self.search_users(keyword:, page: 1, search_id: nil)
    params = { keyword: keyword, page: page }
    params[:search_id] = search_id if search_id.present?

    response = connection.get("/api/v1/xiaohongshu/app_v2/search_users", params, headers)
    handle_response(response)
  end

  # Validate that the configured API key is accepted by the server.
  # Returns true if valid, false if unauthorized, nil on network/unknown error.
  def self.validate_key
    hdrs = headers  # raises ApiKeyMissingError if key is absent
    response = connection.get("/api/v1/xiaohongshu/app_v2/search_users", { keyword: "test", page: 1 }, hdrs) do |req|
      req.options.context = { nocache: true }
    end
    body = JSON.parse(response.body)
    code = body["code"].to_i
    response.status != 401 && response.status != 403 && (body["success"] || code == 0 || code == 200)
  rescue ApiKeyMissingError
    false
  rescue => e
    Rails.logger.warn("TikHub API key validation error: #{e.message}")
    nil
  end

  private

  def self.handle_response(response)
    body_str = response.body
    if body_str.encoding == Encoding::ASCII_8BIT
      body_str = body_str.dup.force_encoding(Encoding::UTF_8)
    end

    case response.status
    when 200
      body = JSON.parse(body_str)
      code = body["code"].to_i
      raise ApiRateLimitError, "API 速率限制：#{body_str}" if code == 429
      unless body["success"] || code == 0 || code == 200
        raise ApiError, "API 返回错误 code=#{code}：#{body['message'] || 'unknown'}"
      end
      body["data"]
    when 401, 403
      raise ApiKeyMissingError, "API 密钥无效或未授权：#{response.status}"
    when 429
      raise ApiRateLimitError, "HTTP 429 速率限制：#{response.status}"
    else
      raise ApiError, "API 错误：#{response.status} - #{body_str}"
    end
  rescue JSON::ParserError => e
    raise ApiError, "无效的 JSON 响应：#{e.message}"
  end
end
