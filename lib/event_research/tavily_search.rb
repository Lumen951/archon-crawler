require "faraday"
require "faraday/retry"
require_relative "search_error"

# Tavily 搜索。带重试的 Faraday 连接；失败抛 ApiError（密钥问题抛 ApiKeyError）。
class EventResearch::TavilySearch
  ENDPOINT = "https://api.tavily.com/search"
  SEARCH_DEPTH = "advanced"

  ApiKeyError = EventResearch::SearchApiKeyError
  ApiError = EventResearch::SearchApiError

  def initialize(api_key:, cache:, reporter:)
    raise ApiKeyError, "TAVILY_API_KEY 未设置" if api_key.to_s.strip.empty?

    @api_key = api_key.strip
    @cache = cache
    @reporter = reporter
  end

  def search(query, limit: 10)
    @cache.wrap("search", [ "tavily", query, limit, SEARCH_DEPTH ].join("|"),
                ttl: EventResearch::CACHE_TTLS["search"], label: "Tavily 搜索: #{query}") do
      perform(query, limit)
    end
  end

  private

  def perform(query, limit)
    @reporter.info("Tavily Search: #{query}")

    started = Time.current
    response = connection.post(ENDPOINT) do |request|
      request.headers["Authorization"] = "Bearer #{@api_key}"
      request.headers["Content-Type"] = "application/json"
      request.body = {
        query: query,
        max_results: limit,
        search_depth: SEARCH_DEPTH,
        include_answer: false,
        include_raw_content: false
      }.to_json
    end

    unless response.success?
      if [ 401, 403, 432, 433 ].include?(response.status)
        raise ApiKeyError, "Tavily 认证失败（HTTP #{response.status}），请检查 TAVILY_API_KEY"
      end

      raise ApiError.new("Tavily 返回 HTTP #{response.status}", status: response.status)
    end

    results = parse_results(response.body)
    @reporter.debug("  Tavily 返回 #{results.length} 条，耗时 #{(Time.current - started).round(1)}s")
    results
  rescue JSON::ParserError => e
    raise ApiError, "Tavily 响应不是合法 JSON: #{e.message}"
  rescue Faraday::Error => e
    raise ApiError, "Tavily 请求失败: #{e.class.name}: #{e.message}"
  end

  def parse_results(body)
    parsed = JSON.parse(body)

    Array(parsed["results"]).filter_map do |item|
      url = item["url"].to_s
      next if url.empty?

      {
        "title" => clean(item["title"]),
        "url" => url,
        "snippet" => clean(item["content"])
      }
    end
  end

  def clean(value)
    value.to_s.scrub.strip
  end

  def connection
    @connection ||= Faraday.new do |faraday|
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
