require "faraday"
require "faraday/retry"

class RednoteApiClient
  BASE_URL = "https://api.yddm.com"

  class ApiError < StandardError
    attr_reader :status_code

    def initialize(message, status_code: nil)
      super(message)
      @status_code = status_code
    end
  end

  class ApiKeyMissingError < ApiError
    def initialize(message = "API 密钥无效或未授权")
      super(message, status_code: 401)
    end
  end

  class ApiRateLimitError < ApiError
    def initialize(message = "速率限制")
      super(message, status_code: 429)
    end
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

  private

  def self.handle_response(response)
    case response.status
    when 200
      body = JSON.parse(response.body)
      code = body["code"].to_i
      raise ApiRateLimitError, "API 速率限制（429）" if code == 429
      unless code == 0
        raise ApiError.new("API 返回错误 code=#{code}：#{body['msg'] || 'unknown'}", status_code: response.status)
      end
      body["data"]
    when 401, 403
      raise ApiKeyMissingError.new("API 密钥无效或未授权（#{response.status}）")
    when 429
      raise ApiRateLimitError.new("HTTP 429 速率限制")
    else
      raise ApiError.new("HTTP #{response.status}：#{response.body.truncate(200)}", status_code: response.status)
    end
  rescue JSON::ParserError => e
    raise ApiError.new("无效的 JSON 响应：#{e.message}")
  end
end
