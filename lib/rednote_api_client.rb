require "bigdecimal"
require "faraday"
require "faraday/retry"
require "response_cache_middleware"

class RednoteApiClient
  BASE_URL = "https://api.yddm.com"

  class ApiError < StandardError
  end

  class ApiInsufficientBalanceError < ApiError
  end

  class ApiKeyMissingError < ApiError
    include CrawlerApiKeyError
  end

  class ApiRateLimitError < ApiError
  end

  # 厂商按次计费，每次响应都带回本次消耗与账户剩余额度。
  # 金额保持 Numeric 原样（整数不被转成浮点，小数不被截断）。
  Usage = Struct.new(:cost, :balance, keyword_init: true)

  def self.connection
    @connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :response_cache
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
  #
  # 可选块会收到本次调用的 Usage（消耗 / 余额），用于记账。块在**抛出业务错误之前**触发：
  # 厂商对返回业务错误的调用同样计费（例如 code 1001 余额不足）。一次调用被重试 N 次就会触发 N 次，
  # 这是正确的 —— 每次尝试都被计费。响应里没有计费字段时不触发。
  def self.get_user_notes(user_id, page: 1, &on_usage)
    # https://s.apifox.cn/6faad22e-3ea1-4934-8926-69d0efb2dce1/435775641e0.md
    response = connection.post("/xhs/user_post3", { user_id: user_id, page: page }.to_json, headers)
    handle_response(response, on_usage)
  end

  # Fetch full detail for a single note.
  # 可选块同 get_user_notes。
  def self.get_note_detail(note_id, &on_usage)
    response = connection.post("/xhs/note_detail4", { note_id: note_id }.to_json, headers)
    handle_response(response, on_usage)
  end

  # Fetch user detail by user_id.
  # Returns data hash with user info; raises on error.
  # 可选块同 get_user_notes。
  def self.get_user_detail(user_id, &on_usage)
    response = connection.post("/xhs/user_detail", { user_id: user_id }.to_json, headers)
    handle_response(response, on_usage)
  end

  # Validate that the configured API key is accepted by the server.
  # Returns true if valid, false if unauthorized, nil on network/unknown error.
  def self.validate_key
    hdrs = headers  # raises ApiKeyMissingError if key is absent
    # https://s.apifox.cn/6faad22e-3ea1-4934-8926-69d0efb2dce1/435775641e0.md
    response = connection.post("/xhs/user_post3", { user_id: "618bdf350000000010004769", page: 1 }.to_json, hdrs)
    body = JSON.parse(response.body)
    Rails.logger.debug("RedNote API key validation response: #{body}")
    # 密钥校验同样按次计费，但没有 crawl_task 可挂，只能记到 Rails 日志
    notify_usage(body, nil)
    response.status != 401 && response.status != 403 && body["code"].to_i == 0
  rescue ApiKeyMissingError
    false
  rescue => e
    Rails.logger.warn("RedNote API key validation error: #{e.message}")
    nil
  end

  private

  def self.handle_response(response, on_usage = nil)
    body_str = response.body
    body_str = body_str.dup.force_encoding(Encoding::UTF_8) if body_str.encoding == Encoding::ASCII_8BIT

    case response.status
    when 200
      body = JSON.parse(body_str)
      # 上报计费信息要放在业务错误判断之前：返回错误的调用同样被计费
      notify_usage(body, on_usage)
      code = body["code"].to_i
      raise ApiRateLimitError, "API 速率限制 (429): #{response.status} - #{body_str}" if code == 429
      unless code == 0
        error_message = "API 返回错误 code=#{code}: #{body['msg'] || 'unknown'}: #{response.status} - #{body_str}"
        if code == 1001
          raise ApiInsufficientBalanceError, error_message
        end
        raise ApiError, error_message
      end
      body["data"]
    when 401, 403
      raise ApiKeyMissingError, "API 密钥无效或未授权: #{response.status} - #{body_str}"
    when 429
      raise ApiRateLimitError, "HTTP 429 速率限制: #{response.status} - #{body_str}"
    else
      raise ApiError, "API 错误: #{response.status} - #{body_str}"
    end
  rescue JSON::ParserError => e
    raise ApiError, "无效的 JSON 响应: #{e.message}"
  end

  # 从响应体里取出计费信息。厂商文档中 cost / balance 位于 data 内，这里同时容忍顶层放置
  # （无法用真实密钥确认嵌套，见 README）。两者都缺失时返回 nil —— 不伪造 0。
  def self.extract_usage(body)
    return nil unless body.is_a?(Hash)

    data = body["data"].is_a?(Hash) ? body["data"] : {}
    cost = coerce_credit(data["cost"]) || coerce_credit(body["cost"])
    balance = coerce_credit(data["balance"]) || coerce_credit(body["balance"])
    return nil if cost.nil? && balance.nil?

    Usage.new(cost: cost, balance: balance)
  end

  # 兼容厂商把金额写成字符串的情况，且不把精确整数变成浮点数。
  def self.coerce_credit(value)
    case value
    when Numeric then value
    when String
      return nil unless value.match?(/\A-?\d+(\.\d+)?\z/)
      value.include?(".") ? BigDecimal(value) : value.to_i
    end
  end

  # 记录并转交计费信息。没有 crawl_task 的调用方（AccountResolver、validate_key）只能靠 Rails 日志留痕。
  #
  # 这里必须吞掉回调抛出的异常：Retryable.with_retry 用 rescue StandardError 包住整个 API 调用，
  # 回调里的异常会被当成"本次调用失败"而**重试，导致重复计费**。
  #
  # 已知边界：Faraday 传输层重试（f.request :retry）发生在 handle_response 之前，被中间件重试掉的
  # 尝试对这里不可见，因此累计消耗可能略低于真实账单。
  def self.notify_usage(body, on_usage)
    usage = extract_usage(body)
    return if usage.nil?

    Rails.logger.info("[RednoteApiClient] API 消耗 #{usage.cost.inspect}，余额 #{usage.balance.inspect}")
    on_usage&.call(usage)
  rescue StandardError => e
    Rails.logger.warn("[RednoteApiClient] 用量回调失败: #{e.class}: #{e.message}")
  end
end
