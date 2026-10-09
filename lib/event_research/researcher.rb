require_relative "search_error"

# 调研主流程。所有外部调用（搜索 / 抓取 / LLM）都经过缓存，中断后重跑即可续上。
#
# 输入除了活动名，还可以带活动账号上配置的补充信息（可选）：
#   keywords          —— 追加搜索词（每条拼成「<活动名> <关键词>」多搜一轮）
#   purpose           —— 研究目的，注入 LLM 提取 prompt，让抽取围绕目的组织
#   other_information —— 其它背景信息，同样注入 prompt 用于消歧
#   seed_url          —— 配置的官方/指定页面，最先抓取、最先拼进 prompt
#
# run 返回最终结果 Hash（{ "event", "awards", "people"?, "companies"?, "metadata" }），
# 由调用方决定落盘方式：CLI 写 output/*.json，应用存进 EventResearchRun.result。
class EventResearch::Researcher
  PERSON_QUERIES = [
    '"%<name>s" 简历',
    '"%<name>s" 教育经历',
    '"%<name>s" 博士',
    '"%<name>s" 硕士',
    '"%<name>s" 工作经历',
    '"%<name>s" 创始人',
    '"%<name>s" CEO',
    '"%<name>s" 联系方式',
    '"%<name>s" 邮箱'
  ].freeze

  SEARCH_LIMIT = 8
  PERSON_SEARCH_LIMIT = 5
  MAX_SEARCH_RESULTS = 80
  PERSON_DOC_LIMIT = 30
  LLM_ATTEMPTS = 3

  # 一眼就不是企业、工商库里必然查不到的机构名，别白花一次调用
  NON_COMPANY_MARKERS = %w[
    大学 学院 学校 中学 小学 研究院 研究所 科学院 医院 政府 协会 学会
    基金会 报社 杂志社 电视台 委员会
  ].freeze
  MIN_COMPANY_NAME_CHARS = 4
  # 经营范围动辄上千字，喂给 LLM 只取开头这段够判断行业了
  MAX_BUSINESS_SCOPE_CHARS = 500

  SYSTEM_PROMPT = <<~PROMPT
    You are a research data extraction agent.

    Research an event, its award-winning projects, organizations,
    and people using ONLY the supplied web documents.

    Do not invent facts.

    If a fact is not found, use null or [].

    Important:
    - A person's phone/email must only be extracted if it is explicitly
      published in the supplied sources.
    - Never infer or guess private contact information.
    - Education and employment must have evidence.
    - Award/rank must have evidence.
    - Project information must have evidence.
    - Prefer official government, organizer, university, company,
      conference and reputable media sources.
    - Preserve source URLs for every extracted fact.

    Company registry records (工商档案) come from Tianyancha, an authoritative
    business registration database. They override any conflicting web source
    for corporate facts: legal representative, registered capital, unified
    social credit code, establishment date, registration status, registered
    address, industry and staff positions. When you state one of those facts
    from such a record, cite its source URL.

    Return valid JSON.
  PROMPT

  def initialize(event:, search:, pages:, llm:, cache:, reporter:, tianyancha: nil,
                 keywords: [], purpose: nil, other_information: nil, seed_url: nil)
    @event = event.to_s.strip
    @keywords = Array(keywords).map { |keyword| keyword.to_s.scrub.strip }.reject(&:empty?)
    @purpose = clean_text(purpose)
    @other_information = clean_text(other_information)
    @seed_url = clean_text(seed_url)
    @search = search
    @pages = pages
    @llm = llm
    @tianyancha = tianyancha
    @cache = cache
    @reporter = reporter
    @fetch_failures = []
    @fetch_failure_count = 0

    # 天眼查：机构名 => 归一化档案（含查无结果的），人名 => 该人在这家公司担任的职位
    @company_profiles = {}
    @person_company_roles = {}
    @tianyancha_stat = { "looked_up" => 0, "found" => 0 }
    @tianyancha_aborted = false
    @tianyancha_limit_reached = false
  end

  def run
    @reporter.info("Event: #{@event}")
    log_research_config
    @reporter.info("-" * 80)

    search_results = discover_event
    @reporter.info("Found #{search_results.length} web sources")

    documents = fetch_seed_document + fetch_documents(search_results, phase: "event")
    @reporter.info("Fetched #{documents.length} documents")

    if documents.empty?
      @reporter.warn("没有抓到任何可用文档，跳过抽取")
      return empty_result(search_results: search_results)
    end

    @reporter.info("Extracting event data...")
    result = llm_json(extraction_prompt(@event, documents), label: "事件抽取")

    people = extract_people(result)
    @reporter.info("Found #{people.length} people")

    # 天眼查要在人物补充之前跑：机构档案会作为附加文档喂给人物抽取的 prompt
    enrich_companies(result)

    merge_enriched_people(result, enrich_people(people))
    # 必须在人物合并之后回填 —— merge_person 会重建整个 person Hash
    attach_tianyancha_links(result)

    result["metadata"] = metadata(search_results, documents, people)

    @reporter.info("=" * 80)
    @reporter.info("调研完成：获奖记录 #{result["awards"].to_a.length} 条，人物 #{people.length} 人")
    @reporter.info("=" * 80)

    result
  end

  private

  def clean_text(value)
    stripped = value.to_s.scrub.strip
    stripped.empty? ? nil : stripped
  end

  def log_research_config
    @reporter.info("Keywords: #{@keywords.join('、')}") if @keywords.any?
    @reporter.info("Purpose: #{@purpose}") if @purpose
    @reporter.info("Other information: #{@other_information}") if @other_information
    @reporter.info("Seed URL: #{@seed_url}") if @seed_url
  end

  # 固定模板 + 账号配置的补充关键词（拼在活动名后面），全部走同一套失败容错。
  def event_queries
    EventResearch::QueryBuilder.new(event: @event, keywords: @keywords).queries
  end

  def discover_event
    queries = event_queries
    failures = 0
    all_results = []

    queries.each do |query|
      begin
        all_results.concat(@search.search(query, limit: SEARCH_LIMIT))
      rescue EventResearch::SearchApiKeyError
        raise
      rescue EventResearch::SearchApiError => e
        failures += 1
        @reporter.error("搜索失败，跳过该词: #{query}（#{e.message}）")
      end
    end

    raise EventResearch::SearchApiError, "全部 #{queries.length} 条搜索都失败了" if all_results.empty?

    @reporter.warn("#{failures} 条搜索失败，已跳过") if failures.positive?
    deduplicate_results(all_results)
  end

  # 账号上配置的官方/指定页面：单独抓取并排进文档最前面 —— 它最相关，
  # prompt 超预算丢尾部文档时最后才会轮到它。失败只警告，不挡住整轮调研。
  def fetch_seed_document
    return [] if @seed_url.nil?

    @reporter.info("抓取种子页面: #{@seed_url}")
    page = @pages.fetch(@seed_url)

    unless page["text"]
      record_fetch_failure(page, "seed")
      @reporter.warn("种子页面抓取失败（#{page['kind']}），继续其余调研")
      return []
    end

    if page["text"].length < EventResearch::MIN_DOC_CHARS
      reason = "正文过短（#{page['text'].length} 字符）"
      record_fetch_failure(page.merge("kind" => "too_short", "error" => reason), "seed")
      @reporter.warn("种子页面#{reason}，丢弃: #{@seed_url}")
      return []
    end

    [ page.merge("title" => page["title"].presence || @seed_url,
                 "search_title" => "配置的种子页面", "search_snippet" => nil) ]
  rescue StandardError => e
    @reporter.error("种子页面抓取异常，已跳过: #{@seed_url}（#{e.class}: #{e.message}）", exception: e)
    []
  end

  def deduplicate_results(results)
    results
      .compact
      .uniq { |item| item["url"] }
      .take(MAX_SEARCH_RESULTS)
  end

  # 事件阶段与人物阶段共用同一套抓取（含把搜索标题回填为文档标题），
  # 之前人物阶段用的是另一份实现，抓到的文档没有标题与摘要。
  def fetch_documents(results, phase:)
    documents = []
    too_short = 0

    # 并发抓取（进度日志在 PageFetcher 里按完成顺序打印），下面仍按搜索结果顺序组装文档
    pages = @pages.fetch_many(results.map { |result| result["url"] })

    results.each_with_index do |result, index|
      page = pages[index] || { "url" => result["url"], "kind" => "network_error", "error" => "抓取未返回结果" }

      unless page["text"]
        record_fetch_failure(page, phase)
        next
      end

      if page["text"].length < EventResearch::MIN_DOC_CHARS
        too_short += 1
        reason = "正文过短（#{page["text"].length} 字符）"
        @reporter.debug("  #{reason}，丢弃: #{result["url"]}")
        record_fetch_failure(page.merge("kind" => "too_short", "error" => reason), phase)
        next
      end

      documents << page.merge(
        "title" => page["title"].to_s.empty? ? result["title"].to_s : page["title"],
        "search_title" => result["title"],
        "search_snippet" => result["snippet"]
      )
    end

    @reporter.warn("#{too_short} 篇文档正文过短已丢弃") if too_short.positive?
    documents
  end

  def record_fetch_failure(page, phase)
    # 计数不截断：清单只留前 50 条，但总数要如实反映（否则 50 条看起来像「就这么多」）
    @fetch_failure_count += 1
    return if @fetch_failures.length >= EventResearch::MAX_FETCH_FAILURES

    @fetch_failures << page.merge("phase" => phase)
  end

  def extract_people(result)
    result.fetch("awards", [])
          .flat_map { |award| award.fetch("people", []) }
          .compact
          .select { |person| person["name"].to_s.strip != "" }
          .uniq { |person| person["name"] }
  end

  # ---- 天眼查（工商信息） ------------------------------------------------

  # 机构档案补全：把「奖项项目所属机构」与「人物任职机构」收敛成一份去重清单，
  # 逐个查天眼查；同时记录每个人在哪家公司担任什么职务（主要人员 + 法定代表人），
  # 这就是「人物本人」的落地方式 —— 全靠响应里已有的 staffList，不需要额外的接口。
  #
  # 密钥没配时整段跳过（只警告一条），不像 SERPER 那样中止整轮调研。
  def enrich_companies(result)
    unless @tianyancha&.configured?
      @reporter.warn("未配置天眼查 API Token（Option.tianyancha_api_key），跳过工商信息补全")
      return
    end

    names = company_queries(result)
    if names.empty?
      @reporter.debug("没有需要查询的机构名，跳过天眼查")
      return
    end

    @reporter.info("天眼查：待查机构 #{names.length} 家")
    names.each { |name| @company_profiles[name] = lookup_company(name) }
    # 只丢掉失败 / 被跳过的（nil）；「查无结果」保留，它也是一条有出处的记录
    @company_profiles.compact!

    @reporter.info("天眼查：命中 #{@tianyancha_stat['found']}/#{@tianyancha_stat['looked_up']} 家" \
                   "（实际请求 #{@tianyancha.performed} 次）")
    index_company_people
  end

  # 从已抽取的结果里收敛出「值得查工商」的机构名。
  # 大学 / 研究院这类在工商库里查不到，直接排除，省下的是真金白银。
  def company_queries(result)
    names = []

    result.fetch("awards", []).each do |award|
      names << award.dig("project", "organization")
      award.fetch("people", []).each do |person|
        person.fetch("employment", []).each { |job| names << job["organization"] }
      end
    end

    names.map { |name| name.to_s.scrub.strip }
         .reject { |name| name.length < MIN_COMPANY_NAME_CHARS }
         .reject { |name| NON_COMPANY_MARKERS.any? { |marker| name.include?(marker) } }
         .uniq
  end

  # 单次查询。查到了和「查过但工商库里没有」都返回档案（后者其实是一份
  # 「我们查过了、没有」的记录，同样带出处）；失败 / 超限返回 nil，
  # 调用方不必区分 —— 失败原因已经写进日志了。
  def lookup_company(name)
    return nil if @tianyancha_aborted || @tianyancha_limit_reached

    @tianyancha_stat["looked_up"] += 1
    profile = @tianyancha.company(name)
    @tianyancha_stat["found"] += 1 if profile["found"]
    profile
  rescue EventResearch::TianyanchaClient::LimitReachedError => e
    @tianyancha_limit_reached = true
    @reporter.warn(e.message)
    nil
  rescue EventResearch::TianyanchaClient::ApiKeyError => e
    # 密钥 / 额度问题：天眼查这一环整体停掉，调研本身继续跑完
    @tianyancha_aborted = true
    @reporter.error("天眼查不可用，其余机构不再查询：#{e.message}")
    nil
  rescue EventResearch::TianyanchaClient::ApiError => e
    @reporter.warn("天眼查查询失败: #{name}（#{e.message}）")
    nil
  end

  # 归一化人名 => [{ "role" => {...写进输出的...}, "profile" => 档案 }]
  def index_company_people
    @company_profiles.each_value do |profile|
      next unless profile["found"]

      company_positions(profile).each do |key, positions|
        (@person_company_roles[key] ||= []) << {
          "role" => {
            "company" => profile["name"],
            "position" => positions.join("、"),
            "source" => profile["source"]
          },
          "profile" => profile
        }
      end
    end
  end

  # 归一化人名 => [职位, ...]（主要人员 + 法定代表人）
  def company_positions(profile)
    positions = {}

    profile["key_people"].to_a.each do |person|
      key = normalize_name(person["name"])
      next if key.empty?

      title = person["position"].to_s
      next if title.empty? || Array(positions[key]).include?(title)

      (positions[key] ||= []) << title
    end

    legal = normalize_name(profile["legal_person"])
    if !legal.empty? && !Array(positions[legal]).include?("法定代表人")
      (positions[legal] ||= []) << "法定代表人"
    end

    positions
  end

  # 该人物相关的公司的档案文档（任职机构 + 本人挂名的公司），去重后渲染成
  # documents_block 认识的形状，append 到人物抽取的 prompt 里。
  def tianyancha_documents(person)
    profiles = []

    person.fetch("employment", []).each do |job|
      profile = @company_profiles[job["organization"].to_s.scrub.strip]
      profiles << profile if profile && profile["found"]
    end

    @person_company_roles.fetch(normalize_name(person["name"]), []).each do |entry|
      profiles << entry["profile"]
    end

    profiles.uniq { |profile| profile["name"] }.map { |profile| company_document(profile) }
  end

  def company_document(profile)
    {
      "url" => profile.dig("source", "url"),
      "title" => "天眼查工商档案：#{profile['name']}",
      "text" => render_company(profile)
    }
  end

  # 渲染成纯文本。URL 必须出现在正文里 —— 模型引用 source_url 时才有依据。
  def render_company(profile)
    lines = [ "天眼查工商档案（权威工商登记信息）" ]
    field = lambda do |label, value|
      lines << "#{label}: #{value}" unless value.to_s.strip.empty?
    end

    field.call("企业名称", profile["name"])
    field.call("统一社会信用代码", profile["credit_code"])
    field.call("法定代表人", profile["legal_person"])
    field.call("注册资本", profile["registered_capital"])
    field.call("成立日期", profile["established_at"])
    field.call("登记状态", profile["status"])
    field.call("企业类型", profile["company_type"])
    field.call("所属行业", profile["industry"])
    field.call("注册地址", profile["reg_location"])
    field.call("联系电话", profile["phone"])
    field.call("邮箱", profile["emails"].to_a.join("、"))
    field.call("官网", profile["website"])
    field.call("标签", profile["tags"].to_a.join("、"))
    field.call("主要人员", profile["key_people"].to_a.map { |person| render_key_person(person) }.join("、"))
    field.call("经营范围", profile["business_scope"].to_s.slice(0, MAX_BUSINESS_SCOPE_CHARS))

    lines << "信息来源: 天眼查 #{profile.dig('source', 'url')}"
    lines.join("\n")
  end

  def render_key_person(person)
    position = person["position"].to_s
    position.empty? ? person["name"].to_s : "#{person['name']}（#{position}）"
  end

  # 把工商档案回填进结果：项目所属公司、人物任职公司，以及「某人在某公司任某职」。
  # 必须跑在 merge_enriched_people 之后 —— merge_person 会重建 person Hash，
  # 之前挂上去的字段会被丢掉。
  def attach_tianyancha_links(result)
    return if @company_profiles.empty?

    result.fetch("awards", []).each do |award|
      project = award["project"]
      if project.is_a?(Hash) && (profile = found_company(project["organization"]))
        project["company"] = profile
      end

      award.fetch("people", []).each do |person|
        person.fetch("employment", []).each do |job|
          profile = found_company(job["organization"])
          job["company"] = profile if profile
        end

        roles = @person_company_roles[normalize_name(person["name"])]
        person["tianyancha"] = { "roles" => roles.map { |entry| entry["role"] } } if roles&.any?
      end
    end

    result["companies"] = @company_profiles.values.select { |profile| profile["found"] }
  end

  # 「查过但这家公司不在工商库里」也有记录（连出处一起），但那不是一个档案，
  # 不该被当成工商事实挂到项目 / 任职上。查无结果只体现在 metadata 与缓存里。
  def found_company(name)
    profile = @company_profiles[name.to_s.scrub.strip]
    profile if profile && profile["found"]
  end

  def tianyancha_metadata
    {
      "enabled" => @tianyancha&.configured? || false,
      "api_calls" => @tianyancha ? @tianyancha.performed : 0,
      "looked_up" => @tianyancha_stat["looked_up"],
      "found" => @tianyancha_stat["found"],
      "aborted" => @tianyancha_aborted || @tianyancha_limit_reached
    }
  end

  # ---- 人物补充 ----------------------------------------------------------

  def enrich_people(people)
    people.each_with_index.map do |person, index|
      enrich_person(person, index, people.length)
    end
  end

  def enrich_person(person, index, total)
    name = person["name"]

    @reporter.info("Research person [#{index + 1}/#{total}]: #{name}")

    results = []
    PERSON_QUERIES.each do |template|
      query = format(template, name: name)

      begin
        results.concat(@search.search(query, limit: PERSON_SEARCH_LIMIT))
      rescue EventResearch::SearchApiKeyError
        raise
      rescue EventResearch::SearchApiError => e
        @reporter.error("搜索失败，跳过该词: #{query}（#{e.message}）")
      end
    end

    documents = fetch_documents(deduplicate_results(results).take(PERSON_DOC_LIMIT), phase: "person:#{name}")
    # 该人相关公司的工商档案（任职机构 + 本人在天眼查里挂名的公司）也一并喂进去，
    # 这样模型给出的工商事实能直接引用天眼查的出处。
    documents += tianyancha_documents(person)

    if documents.empty?
      @reporter.warn("#{name}: 没有可用文档，跳过补充")
      return person
    end

    extracted = llm_json(extraction_prompt("Person research: #{name}", documents), label: "人物抽取: #{name}")
    merge_person(person, extracted_person(extracted))
  rescue EventResearch::SearchApiKeyError
    # 密钥类问题不给人物级别兜底，直接中止整轮
    raise
  rescue StandardError => e
    # 单个人物失败不影响整轮调研，但错误要能查
    @reporter.error("#{name}: 人物调研失败，已跳过", exception: e)
    person
  end

  # 现有 prompt 会让模型把人物信息放在 awards[0].people[0] 或 person 里
  def extracted_person(extracted)
    extracted.dig("awards", 0, "people", 0) || extracted["person"] || {}
  end

  def merge_enriched_people(result, enriched_people)
    by_name = enriched_people.index_by { |person| normalize_name(person["name"]) }
    merged = 0

    result["awards"]&.each do |award|
      award["people"]&.each do |person|
        enriched = by_name[normalize_name(person["name"])]
        next unless enriched

        person.merge!(enriched)
        merged += 1
      end
    end

    @reporter.debug("人物补充信息合并 #{merged} 处")
  end

  # 两次 LLM 输出里的同一个人，可能差在空格 / 全半角括号上，精确匹配会让补充信息悄悄丢掉
  def normalize_name(name)
    name.to_s.scrub.gsub(/\s+/, "").gsub(/[()（）]/, "").strip
  end

  def merge_person(original, extracted)
    {
      "name" => original["name"],
      "role" => extracted["role"] || original["role"],

      "contact" => merge_hash(
        original["contact"],
        extracted["contact"]
      ),

      "education" =>
        extracted["education"].to_a.empty? ?
        original["education"] :
        extracted["education"],

      "employment" =>
        extracted["employment"].to_a.empty? ?
        original["employment"] :
        extracted["employment"],

      "evidence" =>
        (original["evidence"].to_a + extracted["evidence"].to_a)
          .uniq
    }
  end

  def merge_hash(a, b)
    (a || {}).merge(b || {}) do |_key, old_value, new_value|
      new_value.nil? || new_value.to_s.empty? ? old_value : new_value
    end
  end

  # ---- LLM ------------------------------------------------------------

  # 缓存 key 就是 prompt 本身：文档集变了 / 抽取口径变了，key 自然变，
  # 不会拿旧结果顶替；断点续跑时 prompt 不变，直接命中。
  def llm_json(prompt, label:)
    @cache.wrap("llm", "llm:#{Digest::SHA256.hexdigest(prompt)}", ttl: EventResearch::CACHE_TTLS["llm"], label: label,
                cache_if: ->(data) { !EventResearch.degenerate_result?(data) }) do
      @reporter.debug("LLM 调用: #{label}（prompt #{prompt.length} 字符）")
      started = Time.current
      data = generate_with_retry(prompt, label: label)
      @reporter.debug("LLM 完成: #{label}，耗时 #{(Time.current - started).round(1)}s")
      @reporter.warn("LLM 返回空结果（未缓存）: #{label}") if EventResearch.degenerate_result?(data)
      data
    end
  end

  def generate_with_retry(prompt, label:)
    attempt = 0

    begin
      attempt += 1
      @llm.generate_json(prompt)
    rescue LlmClient::ApiError, JSON::ParserError, Faraday::Error => e
      raise if attempt >= LLM_ATTEMPTS

      wait = 2**attempt
      @reporter.warn("LLM 调用失败，#{wait}s 后重试（第 #{attempt} 次）: #{label}（#{e.class}: #{e.message}）")
      sleep(wait)
      retry
    end
  end

  # LlmClient 只接受单一 prompt（无 system role），因此指令与数据拼在一起。
  def extraction_prompt(event, documents)
    <<~PROMPT
      #{SYSTEM_PROMPT}

      Event:
      #{event}
      #{research_context_block}
      Extract all identifiable award-winning / ranked people and projects.

      Return exactly this structure:

      {
        "event": {
          "name": "...",
          "year": null,
          "edition": null
        },
        "awards": [
          {
            "rank": null,
            "award": null,
            "category": null,
            "project": {
              "name": null,
              "description": null,
              "organization": null,
              "industry": null
            },
            "people": [
              {
                "name": null,
                "role": null,

                "contact": {
                  "email": null,
                  "phone": null,
                  "website": null
                },

                "education": [
                  {
                    "school": null,
                    "degree": null,
                    "major": null,
                    "year": null
                  }
                ],

                "employment": [
                  {
                    "organization": null,
                    "title": null,
                    "start_year": null,
                    "end_year": null
                  }
                ],

                "evidence": [
                  {
                    "field": null,
                    "quote": null,
                    "source_url": null
                  }
                ]
              }
            ],

            "evidence": [
              {
                "field": null,
                "quote": null,
                "source_url": null
              }
            ]
          }
        ]
      }

      SOURCES:

      #{documents_block(documents)}
    PROMPT
  end

  # 研究目的与补充信息来自活动账号配置：目的告诉模型这次调研要服务什么决策，
  # 补充信息用于消歧（同名活动、往届届次、举办方口径等）。
  def research_context_block
    context = +""
    context << "\nResearch purpose (调研目的，抽取时优先覆盖这些关注点):\n#{@purpose}\n" if @purpose
    context << "\nAdditional context (背景补充信息):\n#{@other_information}\n" if @other_information
    context
  end

  # 逐篇拼接并守着 MAX_PROMPT_CHARS 预算：超预算就丢尾部（相关性最低）的文档。
  # 之前是无上限拼接（最多 80 篇 × 5 万字符），prompt 过大时模型直接返回空壳。
  def documents_block(documents)
    blocks = []
    total = 0
    dropped = 0

    documents.each_with_index do |doc, index|
      block = <<~DOC
        ===== SOURCE #{index + 1} =====
        URL: #{doc["url"]}
        TITLE: #{doc["title"]}

        #{doc["text"]}
        ===== END SOURCE =====
      DOC

      if blocks.any? && total + block.length > EventResearch::MAX_PROMPT_CHARS
        dropped = documents.length - index
        break
      end

      blocks << block
      total += block.length
    end

    if dropped.positive?
      @reporter.warn("prompt 超出 #{EventResearch::MAX_PROMPT_CHARS} 字符预算，丢弃了最后 #{dropped} 篇文档")
    end
    @reporter.debug("prompt 使用 #{blocks.length}/#{documents.length} 篇文档，#{total} 字符")

    blocks.join("\n")
  end

  # ---- 结果 -----------------------------------------------------------

  def metadata(search_results, documents, people)
    {
      "event_query" => @event,
      "research_config" => {
        "keywords" => @keywords,
        "purpose" => @purpose,
        "other_information" => @other_information,
        "seed_url" => @seed_url
      },
      "sources_searched" => search_results.length,
      "documents_fetched" => documents.length,
      "people_found" => people.length,
      "fetch_failure_count" => @fetch_failure_count,
      "fetch_failures" => @fetch_failures,
      "companies" => tianyancha_metadata,
      "cache" => @cache.stats,
      "generated_at" => Time.current.iso8601
    }
  end

  def empty_result(search_results: [])
    {
      "event" => {
        "name" => @event,
        "year" => nil,
        "edition" => nil
      },
      "awards" => [],
      "metadata" => metadata(search_results, [], [])
    }
  end
end
