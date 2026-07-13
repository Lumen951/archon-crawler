require "faraday"
require "faraday/retry"

class RednoteApiClient
  BASE_URL = "https://api.yddm.com"

  class ApiError < StandardError
  end

  class ApiKeyMissingError < ApiError
  end

  class ApiRateLimitError < ApiError
  end

  def self.connection
    @connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :json
      f.request :retry, max: 3, interval: 1, backoff_factor: 2,
                         exceptions: [ Faraday::TimeoutError, Faraday::ConnectionFailed ]
      f.adapter Faraday.default_adapter
    end
  end

  def self.headers
    key = Option.rednote_api_key
    raise ApiKeyMissingError, "未配置小红书 API 密钥（rednote_api_key）" unless key.present?
    {
      "Content-Type" => "application/json",
      "X-API-Key"    => key,
      "User-Agent"   => "MPCrawler/1.0"
    }
  end

  # Fetch a page of notes for a user.
  # Returns data hash; raises on error.
  def self.get_user_notes(user_id, page: 1)
    response = connection.post("/xhs/user_post3", { user_id: user_id, page: page }.to_json, headers)
    handle_response(response)
  end

  # Fetch full detail for a single note.
  def self.get_note_detail(note_id)
    response = connection.post("/xhs/note_detail4", { note_id: note_id }.to_json, headers)
    handle_response(response)
  end

  # Validate that the configured API key is accepted by the server.
  # Returns true if valid, false if unauthorized, nil on network/unknown error.
  def self.validate_key
    hdrs = headers  # raises ApiKeyMissingError if key is absent
    response = connection.post("/xhs/user_post3", { user_id: "618bdf350000000010004769", page: 1 }.to_json, hdrs)
    body = JSON.parse(response.body.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: ""))
    Rails.logger.debug("RedNote API key validation response: #{body}")
    response.status != 401 && response.status != 403 && body["code"].to_i == 0
  rescue ApiKeyMissingError
    false
  rescue => e
    Rails.logger.warn("RedNote API key validation error: #{e.message}")
    nil
  end

  private

  def self.handle_response(response)
    body_str = response.body.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    case response.status
    when 200
      body = JSON.parse(body_str)
      code = body["code"].to_i
      raise ApiRateLimitError, "API 速率限制（429）：#{response.status} - #{body_str}" if code == 429
      unless code == 0
        raise ApiError, "API 返回错误 code=#{code}：#{body['msg'] || 'unknown'}：#{response.status} - #{body_str}"
      end
      body["data"]
    when 401, 403
      raise ApiKeyMissingError, "API 密钥无效或未授权：#{response.status} - #{body_str}"
    when 429
      raise ApiRateLimitError, "HTTP 429 速率限制：#{response.status} - #{body_str}"
    else
      raise ApiError, "API 错误：#{response.status} - #{body_str}"
    end
  rescue JSON::ParserError => e
    raise ApiError, "无效的 JSON 响应：#{e.message}"
  end
end
