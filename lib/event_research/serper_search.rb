require "faraday"
require "faraday/retry"
require_relative "search_error"

# Serper（Google）搜索。带重试的 Faraday 连接；失败抛 ApiError（密钥问题抛 ApiKeyError）。
class EventResearch::SerperSearch
  ENDPOINT = "https://google.serper.dev/search"
  GL = "cn"
  HL = "zh-cn"

  ApiKeyError = EventResearch::SearchApiKeyError
  ApiError = EventResearch::SearchApiError

  def initialize(api_key:, cache:, reporter:)
    raise ApiKeyError, "SERPER_API_KEY 未设置" if api_key.to_s.strip.empty?

    @api_key = api_key.strip
    @cache = cache
    @reporter = reporter
  end

  def search(query, limit: 10)
    @cache.wrap("search", [ query, limit, GL, HL ].join("|"), ttl: EventResearch::CACHE_TTLS["search"], label: "搜索: #{query}") do
      perform(query, limit)
    end
  end

  private

  def perform(query, limit)
    @reporter.info("Search: #{query}")

    started = Time.current
    response = connection.post(ENDPOINT) do |request|
      request.headers["X-API-KEY"] = @api_key
      request.headers["Content-Type"] = "application/json"
      request.body = { q: query, num: limit, gl: GL, hl: HL }.to_json
    end

    unless response.success?
      if [ 401, 403 ].include?(response.status)
        raise ApiKeyError, "Serper 认证失败（HTTP #{response.status}），请检查 SERPER_API_KEY"
      end

      raise ApiError.new("Serper 返回 HTTP #{response.status}", status: response.status)
    end

    results = parse_results(response.body)
    @reporter.debug("  Serper 返回 #{results.length} 条，耗时 #{(Time.current - started).round(1)}s")
    results
  rescue JSON::ParserError => e
    raise ApiError, "Serper 响应不是合法 JSON: #{e.message}"
  rescue Faraday::Error => e
    # 重试耗尽后的超时 / SSL / 连接失败
    raise ApiError, "Serper 请求失败: #{e.class.name}: #{e.message}"
  end

  def parse_results(body)
    parsed = JSON.parse(body)

    Array(parsed["organic"]).filter_map do |item|
      url = item["link"].to_s
      next if url.empty?

      { "title" => clean(item["title"]), "url" => url, "snippet" => clean(item["snippet"]) }
    end
  end

  def clean(value)
    value.to_s.scrub.strip
  end

  def connection
    @connection ||= Faraday.new do |faraday|
      # faraday-retry 2.x 默认不按状态码重试，且 POST 不在 IDEMPOTENT_METHODS 里：
      # methods/retry_statuses/exceptions 三者缺一，这里的重试都是摆设。
      # max_interval 默认 Float::MAX，没有它一个 Retry-After 能睡一小时。
      faraday.request :retry, max: 3, interval: 1, backoff_factor: 2, max_interval: 10,
                               methods: %i[post],
                               exceptions: [ Faraday::TimeoutError, Faraday::ConnectionFailed,
                                             Faraday::RetriableResponse ],
                               retry_statuses: [ 408, 429, 500, 502, 503, 504 ]
      faraday.options.timeout = 20
      faraday.options.open_timeout = 10
      faraday.adapter Faraday.default_adapter
    end
  end
end
