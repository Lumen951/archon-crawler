require "faraday"
require "faraday/retry"

# 天眼查开放平台。工商事实（法人、注册资本、统一社会信用代码、成立时间、存续状态、
# 公开联系方式）恰恰是网页里最不可靠、又最需要准确的一类信息，所以单独取一份权威数据，
# 并且把出处一并记下来 —— 每条事实都能回答「这是从哪儿来的」。
#
# 只接 baseinfoV3/2.0 一个接口：它是 baseinfo/normal 与 baseinfoV2/2.0 的严格超集
# （工商字段 + 联系方式 + 主要人员一次全给，见 docs/tianyancha_api.md），
# 因此不需要第二个接口。主要人员列表还顺带解决了「某人是否在这家公司任职」——
# 用抽取出的人名和 staffList 交叉比对即可，零额外调用。
#
# 每次调用都过磁盘缓存（按次计费 + 工商数据变化极慢，所以 TTL 给到 30 天）。
class EventResearch::TianyanchaClient
  BASE_URL = "https://open.api.tianyancha.com"
  PATH = "/services/open/ic/baseinfoV3/2.0"
  PROVIDER = "tianyancha"
  API_NAME = "baseinfoV3/2.0"
  # 天眼查详情页，公开可点，作为 source.url
  COMPANY_URL_TEMPLATE = "https://www.tianyancha.com/company/%s"

  # 按次计费。一次调研里真正发出的请求数上限，避免一个活动把整月额度打光。
  # 只统计真打出去的请求：缓存命中不计数。
  DEFAULT_MAX_QUERIES = 40

  # 密钥失效 / 无权限 / 没额度：重试与换个词都没意义
  class ApiKeyError < StandardError; end

  # 暂时性失败（频率过快、超时、5xx）与其余非零错误码都走这里。
  # 它们不写缓存 —— 这次没过，下次可能就过了。
  class ApiError < StandardError
    attr_reader :code

    def initialize(message, code: nil)
      @code = code
      super(message)
    end
  end

  # 达到本次运行的查询上限
  class LimitReachedError < StandardError; end

  # ── 官方错误码 ──────────────────────────────────────
  CODE_NO_RESULT = 300_000       # 查无结果：确定性答案，缓存下来，重跑不再花钱
  CODE_TOO_FREQUENT = 300_004    # 频率过快：暂时性，不缓存
  # 账号失效 / 过期 / 无权限 / 余额不足 / 次数不足 / IP 无权限 / 账号信息有误
  # —— 都属于「Token 该换了」，重试没有意义。
  # 300009 不在文档里，是用一个假 Token 探测真实接口时观察到的（"账号信息有误"）。
  KEY_ERROR_CODES = [ 300_002, 300_003, 300_005, 300_006, 300_007, 300_009, 300_011 ].freeze

  def initialize(api_key:, cache:, reporter:, max_queries: DEFAULT_MAX_QUERIES)
    @api_key = api_key.to_s.strip
    @cache = cache
    @reporter = reporter
    @max_queries = max_queries
    @performed = 0
  end

  # 密钥为空时整段跳过天眼查（调研降级运行），不像 SERPER 那样直接中止
  def configured?
    @api_key.present?
  end

  # 本次运行真正发出的 API 请求数（缓存命中不计）
  attr_reader :performed

  # 按公司名 / 公司ID / 注册号 / 统一社会信用代码查询，返回归一化档案。
  # 查无结果返回 { "found" => false, ... }（同样是确定性结果，进缓存）；
  # 暂时性失败抛 ApiError（不进缓存，重跑会重试）。
  def company(keyword)
    @cache.wrap("tianyancha", "tianyancha:#{keyword}", ttl: EventResearch::CACHE_TTLS["tianyancha"],
                label: "天眼查: #{keyword}") do
      if @performed >= @max_queries
        raise LimitReachedError, "天眼查查询已达本次运行上限 #{@max_queries} 次（按次计费），不再查询其余机构"
      end

      @performed += 1
      perform(keyword)
    end
  end

  private

  def perform(keyword)
    @reporter.debug("天眼查查询: #{keyword}")
    started = Time.current

    response = connection.get(PATH) do |request|
      request.params["keyword"] = keyword
      request.headers["Authorization"] = @api_key
    end

    unless response.success?
      raise ApiError.new("天眼查返回 HTTP #{response.status}", code: response.status)
    end

    envelope = parse(response.body)
    code = envelope["error_code"].to_i
    reason = envelope["reason"].to_s

    return not_found(keyword) if code == CODE_NO_RESULT

    if KEY_ERROR_CODES.include?(code)
      raise ApiKeyError, "天眼查认证/额度失败（error_code=#{code}，#{reason}），请检查 /admin/settings 里的 Token"
    end

    unless code.zero?
      # 300004（频率过快）走这里：不缓存，重跑会重试
      message = code == CODE_TOO_FREQUENT ? "天眼查频率过快" : "天眼查返回 error_code=#{code}"
      raise ApiError.new("#{message}（#{reason}）", code: code)
    end

    profile = normalize(envelope["result"], keyword)
    @reporter.debug("  天眼查命中 #{profile['name']}，耗时 #{(Time.current - started).round(1)}s")
    profile
  rescue JSON::ParserError => e
    raise ApiError, "天眼查响应不是合法 JSON: #{e.message}"
  rescue Faraday::Error => e
    # 重试耗尽后的超时 / SSL / 连接失败
    raise ApiError, "天眼查请求失败: #{e.class.name}: #{e.message}"
  end

  def parse(body)
    parsed = JSON.parse(body)
    parsed.is_a?(Hash) ? parsed : {}
  end

  # 归一化：把天眼查的字段名换成内部的口径，并把 source 一并带上。
  # 之后所有工商结论都从这里取，出处不会丢。
  def normalize(result, keyword)
    result = {} unless result.is_a?(Hash)

    {
      "found" => true,
      "query" => keyword,
      "name" => text(result["name"]),
      "credit_code" => text(result["creditCode"]),
      "legal_person" => text(result["legalPersonName"]),
      "registered_capital" => text(result["regCapital"]),
      "established_at" => date(result["estiblishTime"]),
      "status" => text(result["regStatus"]),
      "company_type" => text(result["companyOrgType"]),
      "industry" => text(result["industry"]),
      "reg_location" => text(result["regLocation"]),
      "business_scope" => text(result["businessScope"]),
      "phone" => text(result["phoneNumber"]),
      "emails" => string_list(result["emailList"]),
      "website" => text(result["websiteList"]),
      "tags" => text(result["tags"]).split(";").map(&:strip).reject(&:empty?),
      "key_people" => key_people(result.dig("staffList", "result")),
      "source" => source(keyword, result["id"])
    }
  end

  def not_found(keyword)
    {
      "found" => false,
      "query" => keyword,
      "name" => keyword,
      "source" => source(keyword, nil)
    }
  end

  def source(keyword, id)
    {
      "provider" => PROVIDER,
      "api" => API_NAME,
      "url" => company_url(id),
      "query" => keyword,
      "queried_at" => Time.current.iso8601
    }
  end

  def company_url(id)
    value = id.to_s.strip
    value.empty? ? nil : format(COMPANY_URL_TEMPLATE, value)
  end

  # staffList.result[] 形如 { "name" => "姬苏春", "typeJoin" => ["董事长"] }
  def key_people(staff)
    Array(staff).filter_map do |person|
      next unless person.is_a?(Hash)

      name = text(person["name"])
      next if name.empty?

      { "name" => name, "position" => string_list(person["typeJoin"]).join("、") }
    end
  end

  # estiblishTime 是毫秒时间戳（如 847900800000 → 1996-11-14），不是秒
  def date(value)
    millis = value.to_i
    return nil if millis <= 0

    Time.zone.at(millis / 1000).strftime("%Y-%m-%d")
  end

  def string_list(value)
    Array(value).map { |item| text(item) }.reject(&:empty?).uniq
  end

  def text(value)
    value.to_s.scrub.strip
  end

  # 与项目里其它连接一致：传输层重试交给 faraday-retry。
  # 这条连接**不**放宽 TLS 校验 —— 天眼查是证书正常的商业端点，而请求头里带着
  # Token（凭据），关掉校验是纯损失。
  def connection
    @connection ||= Faraday.new(url: BASE_URL) do |faraday|
      faraday.request :retry, max: 2, interval: 0.5, backoff_factor: 2, max_interval: 10,
                               exceptions: [ Faraday::TimeoutError, Faraday::ConnectionFailed ],
                               retry_statuses: [ 408, 429, 500, 502, 503, 504 ]
      faraday.options.timeout = 15
      faraday.options.open_timeout = 10
      faraday.adapter Faraday.default_adapter
    end
  end
end
