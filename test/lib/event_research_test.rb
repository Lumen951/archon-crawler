require "test_helper"
require "tmpdir"

# 活动调研核心流程（lib/event_research/）的离线测试：
# 缓存 / 日志 / 搜索 / 抓取包装 / 配置注入 / 天眼查接入 / 端到端。
# 全程不联网（外部 HTTP 与 LLM 一律打桩），缓存目录指向 Dir.mktmpdir。
# CLI 专属的落盘与日志格式测试在 test/lib/event_research_cli_test.rb。
class EventResearchTest < ActiveSupport::TestCase
  def setup
    @tmpdir = Dir.mktmpdir("event-research-test")
    @messages = []
    @reporter = EventResearch::Reporter.new(->(level, message) { @messages << [ level, message ] })
    @cache = EventResearch::RunCache.new(root: @tmpdir, reporter: @reporter)
  end

  def teardown
    @reporter.close
    FileUtils.remove_entry(@tmpdir)
  end

  # --- RunCache -----------------------------------------------------------

  test "wrap 第一次执行块并写盘，第二次直接命中不再执行" do
    calls = 0
    memoized = -> { @cache.wrap("search", "key", ttl: 60) { calls += 1; [ "结果" ] } }

    assert_equal [ "结果" ], memoized.call
    assert_equal [ "结果" ], memoized.call
    assert_equal 1, calls, "第二次应命中缓存"
    assert_equal 1, @cache.stats["search"]["hit"]
  end

  test "超过 TTL 的条目不再命中" do
    @cache.write("search", "key", [ "旧数据" ], label: "旧")
    expire_cache_entry("search", "key")

    assert_equal [ "新数据" ], @cache.wrap("search", "key", ttl: 60) { [ "新数据" ] }
  end

  test "损坏的缓存文件当作未命中且不抛异常" do
    @cache.write("search", "key", [ "数据" ])
    File.write(cache_path("search", "key"), "{ 半截 JSON")

    assert_equal [ "重算" ], @cache.wrap("search", "key", ttl: 60) { [ "重算" ] }
  end

  test "cache_if 为假时不写缓存，下次仍会重新执行" do
    calls = 0
    fetch = lambda do
      @cache.wrap("document", "key", ttl: 60, cache_if: ->(value) { value["ok"] }) do
        calls += 1
        { "ok" => false }
      end
    end

    fetch.call
    fetch.call

    assert_equal 2, calls
    assert_equal 0, @cache.stats["document"]["write"]
  end

  test "refresh 模式忽略已有条目，但仍然写回" do
    @cache.write("search", "key", [ "旧数据" ])
    refreshing = EventResearch::RunCache.new(root: @tmpdir, reporter: @reporter, refresh: true)

    assert_equal [ "新数据" ], refreshing.wrap("search", "key", ttl: 60) { [ "新数据" ] }
    assert_equal [ "新数据" ], @cache.wrap("search", "key", ttl: 60) { [ "不应执行" ] }, "refresh 应写回新值"
  end

  test "写盘是原子的，不留 tmp 文件" do
    @cache.write("search", "key", [ "数据" ])

    assert_empty Dir.glob(File.join(@tmpdir, "cache", "**", "*.tmp"))
  end

  test "不同 key 落到不同文件，互不覆盖" do
    @cache.write("search", "a", [ 1 ])
    @cache.write("search", "b", [ 2 ])

    assert_equal [ 1 ], @cache.read("search", "a", ttl: 60)
    assert_equal [ 2 ], @cache.read("search", "b", ttl: 60)
  end

  test "统计覆盖所有 namespace，未使用过的补 0" do
    assert_equal %w[document llm search tianyancha], @cache.stats.keys.sort
    assert_equal({ "hit" => 0, "miss" => 0, "write" => 0 }, @cache.stats["llm"])
  end

  # --- Reporter -----------------------------------------------------------

  test "所有级别都送到 sink，error 记录 backtrace" do
    @reporter.info("普通信息")
    @reporter.debug("调试信息")

    begin
      raise ArgumentError, "出错了"
    rescue ArgumentError => e
      @reporter.error("操作失败", exception: e)
    end

    levels = @messages.map(&:first)
    assert_includes levels, :info
    assert_includes levels, :debug
    assert_equal [ :error, :error, :error ], levels.last(3)

    texts = @messages.map(&:last)
    assert_includes texts, "普通信息"
    assert_includes texts, "  ArgumentError: 出错了"
    assert texts.grep(/event_research_test\.rb/).any?, "应写入 backtrace"
  end

  test "日志会把 URL 里的代理账号密码打码" do
    @reporter.info("proxy http://user:secret@127.0.0.1:7890 不可用")

    texts = @messages.map(&:last)

    assert_includes texts.grep(/proxy/).first, "http://***@127.0.0.1:7890"
    assert texts.grep(/secret/).empty?
  end

  # --- SerperSearch -------------------------------------------------------

  test "搜索结果进缓存，第二次不再请求" do
    conn, requests = fake_serper_connection(status: 200, body: {
      "organic" => [ { "title" => "标题", "link" => "https://a.com/1", "snippet" => "摘要" } ]
    }.to_json)
    search = serper_search(conn)

    first = search.search("关键词")
    second = search.search("关键词")

    assert_equal [ { "title" => "标题", "url" => "https://a.com/1", "snippet" => "摘要" } ], first
    assert_equal first, second
    assert_equal 1, requests.length, "第二次应命中缓存"
    assert_equal "test-key", requests.first.headers["X-API-KEY"]
  end

  test "搜索鉴权失败抛 ApiKeyError 且不写缓存" do
    conn, = fake_serper_connection(status: 401, body: "unauthorized")

    assert_raises(EventResearch::SerperSearch::ApiKeyError) { serper_search(conn).search("关键词") }
    assert_equal 0, @cache.stats["search"]["write"]
  end

  test "搜索 5xx 抛 ApiError（不是密钥错误）" do
    conn, = fake_serper_connection(status: 503, body: "unavailable")

    error = assert_raises(EventResearch::SerperSearch::ApiError) { serper_search(conn).search("关键词") }
    assert_equal 503, error.status
    assert_equal 0, @cache.stats["search"]["write"]
  end

  test "缺少 SERPER_API_KEY 时构造即失败" do
    assert_raises(EventResearch::SerperSearch::ApiKeyError) do
      EventResearch::SerperSearch.new(api_key: "  ", cache: @cache, reporter: @reporter)
    end
  end

  # --- TavilySearch -------------------------------------------------------

  test "Tavily 搜索结果进缓存，使用 Bearer 认证并归一化 content" do
    conn, requests = fake_tavily_connection(status: 200, body: {
      "results" => [
        { "title" => "标题", "url" => "https://a.com/1", "content" => "正文摘要" },
        { "title" => "缺 URL", "content" => "应忽略" }
      ]
    }.to_json)
    search = tavily_search(conn)

    first = search.search("关键词", limit: 5)
    second = search.search("关键词", limit: 5)

    assert_equal [ { "title" => "标题", "url" => "https://a.com/1", "snippet" => "正文摘要" } ], first
    assert_equal first, second
    assert_equal 1, requests.length, "第二次应命中缓存"
    assert_equal "Bearer test-key", requests.first.headers["Authorization"]
    body = JSON.parse(requests.first.body)
    assert_equal "关键词", body["query"]
    assert_equal 5, body["max_results"]
  end

  test "Tavily 搜索鉴权失败抛 ApiKeyError 且不写缓存" do
    conn, = fake_tavily_connection(status: 401, body: "unauthorized")

    assert_raises(EventResearch::TavilySearch::ApiKeyError) { tavily_search(conn).search("关键词") }
    assert_equal 0, @cache.stats["search"]["write"]
  end

  test "Tavily 搜索 5xx 抛 ApiError 且保留 HTTP 状态" do
    conn, = fake_tavily_connection(status: 503, body: "unavailable")

    error = assert_raises(EventResearch::TavilySearch::ApiError) { tavily_search(conn).search("关键词") }
    assert_equal 503, error.status
    assert_equal 0, @cache.stats["search"]["write"]
  end

  test "缺少 TAVILY_API_KEY 时构造即失败" do
    assert_raises(EventResearch::TavilySearch::ApiKeyError) do
      EventResearch::TavilySearch.new(api_key: "  ", cache: @cache, reporter: @reporter)
    end
  end


  test "天眼查结果进缓存，第二次不再请求" do
    conn, requests = fake_tianyancha_connection(body: tianyancha_body.to_json)
    client = tianyancha_client(conn)

    first = client.company("中航重机股份有限公司")
    second = client.company("中航重机股份有限公司")

    assert_equal first, second
    assert_equal 1, requests.length, "第二次应命中缓存"
    assert_equal 1, client.performed, "缓存命中不该计入本次运行的请求数"
    assert_equal "test-token", requests.first.headers["Authorization"]
    assert_equal "中航重机股份有限公司", requests.first.params["keyword"]
  end

  test "天眼查字段归一化，且每条都带得回出处" do
    conn, = fake_tianyancha_connection(body: tianyancha_body.to_json)

    profile = tianyancha_client(conn).company("中航重机股份有限公司")

    assert profile["found"]
    assert_equal "中航重机股份有限公司", profile["name"]
    assert_equal "91520000214434146R", profile["credit_code"]
    assert_equal "姬苏春", profile["legal_person"]
    assert_equal "77800.32万人民币", profile["registered_capital"]
    assert_equal "1996-11-14", profile["established_at"], "estiblishTime 是毫秒时间戳，需要 /1000"
    assert_equal "存续", profile["status"]
    assert_equal [ "zhzjgk@163.com", "zhzj@avic.com" ], profile["emails"]
    assert_equal %w[存续 曾用名 A股], profile["tags"]
    assert_equal [ { "name" => "姬苏春", "position" => "董事长" },
                   { "name" => "崔龙", "position" => "监事" } ], profile["key_people"]

    source = profile["source"]
    assert_equal "tianyancha", source["provider"]
    assert_equal "baseinfoV3/2.0", source["api"]
    assert_equal "https://www.tianyancha.com/company/11684584", source["url"]
    assert_equal "中航重机股份有限公司", source["query"]
    assert source["queried_at"].present?
  end

  test "天眼查查无结果是确定性答案，写进缓存" do
    conn, requests = fake_tianyancha_connection(
      body: { "result" => nil, "reason" => "无结果", "error_code" => 300_000 }.to_json
    )
    client = tianyancha_client(conn)

    assert_equal false, client.company("查无此公司有限公司")["found"]
    assert_equal false, client.company("查无此公司有限公司")["found"]
    assert_equal 1, requests.length
    assert_equal 1, @cache.stats["tianyancha"]["write"]
  end

  test "天眼查频率过快抛 ApiError 且不写缓存（暂时性失败，重跑要重试）" do
    conn, = fake_tianyancha_connection(body: { "reason" => "请求过快", "error_code" => 300_004 }.to_json)

    error = assert_raises(EventResearch::TianyanchaClient::ApiError) { tianyancha_client(conn).company("某公司") }
    assert_equal 300_004, error.code
    assert_equal 0, @cache.stats["tianyancha"]["write"]
  end

  test "天眼查账号失效抛 ApiKeyError 且不写缓存" do
    conn, = fake_tianyancha_connection(body: { "reason" => "账号已失效", "error_code" => 300_003 }.to_json)

    assert_raises(EventResearch::TianyanchaClient::ApiKeyError) { tianyancha_client(conn).company("某公司") }
    assert_equal 0, @cache.stats["tianyancha"]["write"]
  end

  test "天眼查 HTTP 5xx 抛 ApiError 且不写缓存" do
    conn, = fake_tianyancha_connection(status: 503, body: "unavailable")

    assert_raises(EventResearch::TianyanchaClient::ApiError) { tianyancha_client(conn).company("某公司") }
    assert_equal 0, @cache.stats["tianyancha"]["write"]
  end

  test "天眼查未配置密钥时不算可用，也不发请求" do
    client = EventResearch::TianyanchaClient.new(api_key: "  ", cache: @cache, reporter: @reporter)

    assert_not client.configured?
  end

  test "天眼查达到本次运行上限后不再发请求" do
    conn, requests = fake_tianyancha_connection(body: tianyancha_body.to_json)
    client = tianyancha_client(conn, max_queries: 1)

    client.company("公司甲")

    assert_raises(EventResearch::TianyanchaClient::LimitReachedError) { client.company("公司乙") }
    assert_equal 1, requests.length, "上限之后不该再打接口"
    assert_equal 1, client.performed
  end

  # --- PageFetcher --------------------------------------------------------

  test "抓取成功的页面写缓存，超时之类不写缓存" do
    fetch_count = 0
    outcomes = {
      "https://a.com/ok" => WebsiteCrawler::FetchResult.success(
        url: "https://a.com/ok",
        html: "<html><head><title>标题</title></head><body>#{'正文' * 100}</body></html>"
      ),
      "https://a.com/down" => WebsiteCrawler::FetchResult.failure(
        url: "https://a.com/down", kind: :timeout, error: "Net::ReadTimeout"
      )
    }

    with_fake_website_fetcher(->(url) { fetch_count += 1; outcomes.fetch(url) }) do
      pages = EventResearch::PageFetcher.new(cache: @cache, reporter: @reporter)

      ok = pages.fetch("https://a.com/ok")
      assert_equal "success", ok["kind"]
      assert_equal "标题", ok["title"]
      assert_operator ok["text"].length, :>, EventResearch::MIN_DOC_CHARS

      failed = pages.fetch("https://a.com/down")
      assert_equal "timeout", failed["kind"]
      assert_equal "Net::ReadTimeout", failed["error"]
      assert_nil failed["text"]

      # 成功的那条命中缓存，失败的那条会重试
      pages.fetch("https://a.com/ok")
      pages.fetch("https://a.com/down")

      assert_equal 3, fetch_count, "成功页面应命中缓存，失败页面应重新抓取"
      assert_equal 1, @cache.stats["document"]["hit"]
    end
  end

  test "抓不到正文的页面记为 empty 并缓存（确定性结果，不必重抓）" do
    fetch_count = 0
    with_fake_website_fetcher(->(url) { fetch_count += 1; WebsiteCrawler::FetchResult.success(url: url, html: "<html><body><script>js</script></body></html>") }) do
      pages = EventResearch::PageFetcher.new(cache: @cache, reporter: @reporter)

      assert_equal "empty", pages.fetch("https://a.com/shell")["kind"]
      assert_equal "empty", pages.fetch("https://a.com/shell")["kind"]
      assert_equal 1, fetch_count
    end
  end

  test "反爬验证页归为 blocked 且不写缓存，重跑会再试" do
    fetch_count = 0
    # 百度百科对非浏览器客户端返回的「安全校验中…」空壳（真实抓包内容，200 + 正文极短）
    html = "<html><head><title>百度百科</title></head><body><div>安全校验中…</div>" \
           "<script>window.location</script></body></html>"

    with_fake_website_fetcher(->(url) { fetch_count += 1; WebsiteCrawler::FetchResult.success(url: url, html: html) }) do
      pages = EventResearch::PageFetcher.new(cache: @cache, reporter: @reporter)

      assert_equal "blocked", pages.fetch("https://baike.baidu.com/item/x")["kind"]
      assert_equal "blocked", pages.fetch("https://baike.baidu.com/item/x")["kind"]
      assert_equal 2, fetch_count, "验证页不是确定性结果，不该被缓存"
      assert_equal 0, @cache.stats["document"]["write"]
    end
  end

  test "PDF 等非 HTML 资源也不会被反复重抓" do
    fetch_count = 0
    with_fake_website_fetcher(->(url) { fetch_count += 1; WebsiteCrawler::FetchResult.failure(url: url, kind: :unsupported, error: "非 HTML 资源") }) do
      pages = EventResearch::PageFetcher.new(cache: @cache, reporter: @reporter)

      assert_equal "unsupported", pages.fetch("https://a.com/a.pdf")["kind"]
      assert_equal "unsupported", pages.fetch("https://a.com/a.pdf")["kind"]
      assert_equal 1, fetch_count
    end
  end

  # --- prompt 预算、姓名归一化与配置注入 -------------------------------------

  test "prompt 超出预算时丢掉尾部文档" do
    researcher = build_researcher
    documents = Array.new(5) { |i| { "url" => "https://a.com/#{i}", "title" => "标题", "text" => "正" * 500 } }

    stub_const_value(EventResearch, "MAX_PROMPT_CHARS", 1_200) do
      block = researcher.send(:documents_block, documents)

      assert_includes block, "SOURCE 1"
      assert_not_includes block, "SOURCE 5"
    end
  end

  test "姓名归一化让全半角括号与空格的同一人合并" do
    researcher = build_researcher
    result = { "awards" => [ { "people" => [ { "name" => "张三（清华）" } ] } ] }

    researcher.send(:merge_enriched_people, result, [ { "name" => "张三 (清华)", "role" => "CEO" } ])

    assert_equal "CEO", result["awards"][0]["people"][0]["role"]
  end

  test "固定与追加搜索组合按顺序执行" do
    search = recording_search

    run_research(search: search, pages: fake_page_fetcher(->(url) { success_page(url) }), llm: fake_llm,
                 keywords: [ "路演", "决赛" ])

    assert_equal [
      '"测试大会" 获奖名单',
      '"测试大会" 获奖项目',
      '"测试大会" 获奖人',
      '"测试大会" 决赛 获奖',
      '"测试大会" 总决赛',
      '"测试大会" 一等奖 二等奖 三等奖',
      '"测试大会" TOP50',
      '"测试大会" TOP100',
      '"测试大会" 排名',
      '"测试大会" 项目名单',
      '"测试大会" 参赛项目',
      '"测试大会" 创始人',
      '"测试大会" CEO',
      "测试大会 路演",
      "测试大会 决赛"
    ], search.queries.first(15)
  end

  test "研究目的与补充信息注入抽取 prompt" do
    researcher = build_researcher(purpose: "找出获奖项目创始人", other_information: "仅统计 2025 届")

    prompt = researcher.send(:extraction_prompt, "测试大会", [])

    assert_includes prompt, "找出获奖项目创始人"
    assert_includes prompt, "仅统计 2025 届"
  end

  test "没有配置研究目的与补充信息时 prompt 不含对应小节" do
    researcher = build_researcher

    prompt = researcher.send(:extraction_prompt, "测试大会", [])

    assert_not_includes prompt, "Research purpose"
    assert_not_includes prompt, "Additional context"
  end

  test "metadata.research_config 记录本轮调研的配置，结果自包含" do
    result = run_research(
      search: recording_search, pages: fake_page_fetcher(->(url) { success_page(url) }),
      llm: fake_llm,
      keywords: [ "路演" ], purpose: "找出创始人", other_information: "2025 届", seed_url: "https://a.com/official"
    )

    config = result["metadata"]["research_config"]
    assert_equal [ "路演" ], config["keywords"]
    assert_equal "找出创始人", config["purpose"]
    assert_equal "2025 届", config["other_information"]
    assert_equal "https://a.com/official", config["seed_url"]
  end

  test "种子页面最先抓取，失败不挡住整轮调研" do
    fetches = []
    pages = fake_page_fetcher(lambda do |url|
      fetches << url
      url == "https://a.com/official" ? { "url" => url, "kind" => "timeout", "error" => "超时" } : success_page(url)
    end)

    result = run_research(search: recording_search, pages: pages, llm: fake_llm, seed_url: "https://a.com/official")

    assert_equal "https://a.com/official", fetches.first, "种子页面第一个抓"
    assert_equal 1, result["metadata"]["documents_fetched"], "种子失败后其余文档照常抓取"
    assert_includes result["metadata"]["fetch_failures"].map { |failure| failure["phase"] }, "seed"
  end

  test "种子页面成功时排在分析材料最前" do
    pages = fake_page_fetcher(->(url) { success_page(url) })
    prompts = []
    llm = fake_object({
      generate_json: lambda do |prompt|
        prompts << prompt
        { "awards" => [ { "rank" => "一等奖", "people" => [ { "name" => "张三" } ] } ] }
      end
    })

    result = run_research(search: recording_search, pages: pages, llm: llm, seed_url: "https://a.com/official")

    assert_equal 2, result["metadata"]["documents_fetched"]
    assert_operator prompts.first.index("https://a.com/official"), :<, prompts.first.index("https://a.com/1"),
                   "种子页面应排在 prompt 的第一个来源"
  end

  test "slug 保留中文并兜底空值" do
    assert_equal "科创中国创新创业投资大会", EventResearch.slug("科创中国创新创业投资大会")
    assert_equal "a-b", EventResearch.slug("A / B")
    assert_equal "event", EventResearch.slug("!!!")
  end

  test "退化结果判定：没有获奖与人物就算退化" do
    assert EventResearch.degenerate_result?({ "awards" => [] })
    assert EventResearch.degenerate_result?(nil)
    assert_not EventResearch.degenerate_result?({ "awards" => [ { "rank" => "一等奖" } ] })
  end

  # --- 天眼查接入调研流程 ---------------------------------------------------

  test "未配置天眼查密钥时跳过工商补全，调研本身照常完成" do
    search, pages, llm = fake_research_dependencies
    tianyancha = EventResearch::TianyanchaClient.new(api_key: nil, cache: @cache, reporter: @reporter)

    result = run_research(search: search, pages: pages, llm: llm, tianyancha: tianyancha)

    assert_equal "张三", result.dig("awards", 0, "people", 0, "name"), "没有天眼查也要正常出结果"
    assert_not result["metadata"]["companies"]["enabled"]
    assert_equal 0, result["metadata"]["companies"]["api_calls"]
    assert_not result.key?("companies")
  end

  test "天眼查机构档案回填到项目与任职记录，并带上出处" do
    result = tianyancha_research_result

    person = result["awards"][0]["people"][0]
    assert_equal "中航重机股份有限公司", result["awards"][0]["project"]["company"]["name"]
    assert_equal "91520000214434146R", result["awards"][0]["project"]["company"]["credit_code"]
    assert_equal "中航重机股份有限公司", person["employment"][0]["company"]["name"]
    assert_equal "https://www.tianyancha.com/company/11684584",
                 person["employment"][0]["company"]["source"]["url"]
    assert_equal [ "中航重机股份有限公司" ], result["companies"].map { |company| company["name"] }
  end

  test "主要人员与抽取出的人名交叉比对，写入 person.tianyancha.roles" do
    roles = tianyancha_research_result.dig("awards", 0, "people", 0, "tianyancha", "roles")

    assert_equal 1, roles.length
    assert_equal "中航重机股份有限公司", roles[0]["company"]
    assert_equal "监事", roles[0]["position"]
    assert_equal "https://www.tianyancha.com/company/11684584", roles[0]["source"]["url"]
  end

  test "人名对不上主要人员时，不产生任职记录" do
    result = tianyancha_research_result(person_name: "查无此人")

    assert_not result["awards"][0]["people"][0].key?("tianyancha")
  end

  test "查无结果的机构不算档案，不挂到项目上，但计入 metadata" do
    body = { "result" => nil, "reason" => "无结果", "error_code" => 300_000 }
    result = tianyancha_research_result(body: body)

    assert_not result["awards"][0]["project"].key?("company")
    assert_not result["awards"][0]["people"][0]["employment"][0].key?("company")
    assert_empty result["companies"], "查过但没查到，companies 应为空数组而不是缺失"
    assert_equal 1, result["metadata"]["companies"]["looked_up"]
    assert_equal 0, result["metadata"]["companies"]["found"]
  end

  test "法定代表人即使不在主要人员列表里也会被交叉比对到" do
    roles = tianyancha_research_result(person_name: "姬苏春").dig("awards", 0, "people", 0, "tianyancha", "roles")

    assert_equal [ "董事长", "法定代表人" ], roles[0]["position"].split("、")
  end

  test "天眼查任职记录在人物合并之后回填，不会被 merge_person 冲掉" do
    researcher = build_researcher(tianyancha: tianyancha_client(fake_tianyancha_connection(body: tianyancha_body.to_json).first))
    result = { "awards" => [ { "project" => { "organization" => "中航重机股份有限公司" },
                              "people" => [ { "name" => "崔龙",
                                              "employment" => [ { "organization" => "中航重机股份有限公司" } ] } ] } ] }

    researcher.send(:enrich_companies, result)
    # 模拟人物补充：LLM 换了一整套 employment，之前挂在旧数组上的 company 会随之消失
    researcher.send(:merge_enriched_people, result,
                    [ { "name" => "崔龙", "role" => "监事",
                        "employment" => [ { "organization" => "中航重机股份有限公司", "title" => "监事" } ] } ])
    researcher.send(:attach_tianyancha_links, result)

    person = result["awards"][0]["people"][0]
    assert_equal "监事", person["role"], "人物补充信息应已合并"
    assert_equal "监事", person["employment"][0]["title"]
    assert_equal "中航重机股份有限公司", person["employment"][0]["company"]["name"], "回填要在合并之后"
    assert_equal "监事", person["tianyancha"]["roles"][0]["position"]
  end

  test "大学 / 研究院这类查不到工商登记的机构不浪费调用次数" do
    conn, requests = fake_tianyancha_connection(body: tianyancha_body.to_json)
    researcher = build_researcher(tianyancha: tianyancha_client(conn))
    result = { "awards" => [ { "project" => { "organization" => "清华大学" },
                              "people" => [ { "name" => "张三",
                                              "employment" => [ { "organization" => "中国科学院研究院" },
                                                                { "organization" => "中航重机股份有限公司" } ] } ] } ] }

    researcher.send(:enrich_companies, result)

    assert_equal 1, requests.length, "只该查那一家企业"
    assert_equal "中航重机股份有限公司", requests.first.params["keyword"]
  end

  test "工商档案渲染成附加文档喂进人物抽取 prompt" do
    researcher = build_researcher(tianyancha: tianyancha_client(fake_tianyancha_connection(body: tianyancha_body.to_json).first))
    result = company_result("崔龙")

    researcher.send(:enrich_companies, result)
    documents = researcher.send(:tianyancha_documents, result["awards"][0]["people"][0])

    assert_equal 1, documents.length
    assert_equal "https://www.tianyancha.com/company/11684584", documents.first["url"]
    assert_includes documents.first["text"], "统一社会信用代码: 91520000214434146R"
    assert_includes documents.first["text"], "信息来源: 天眼查 https://www.tianyancha.com/company/11684584"
  end

  test "天眼查密钥失效时只停掉这一环，调研继续" do
    conn, requests = fake_tianyancha_connection(body: { "reason" => "账号已失效", "error_code" => 300_003 }.to_json)
    researcher = build_researcher(tianyancha: tianyancha_client(conn))
    result = { "awards" => [ { "project" => { "organization" => "甲公司有限公司" },
                              "people" => [ { "name" => "张三",
                                              "employment" => [ { "organization" => "乙公司有限公司" } ] } ] } ] }

    researcher.send(:enrich_companies, result)

    assert_equal 1, requests.length, "密钥失效后不该再逐家重试"
    assert_not result.key?("companies")
  end

  # --- 端到端（全部打桩） --------------------------------------------------

  test "调研流程串起来：搜索→抓取→抽取→补充→返回结果" do
    search, pages, llm = fake_research_dependencies

    result = run_research(search: search, pages: pages, llm: llm)

    assert_equal "张三", result.dig("awards", 0, "people", 0, "name")
    assert_equal 1, result["metadata"]["people_found"]
    assert_operator result["metadata"]["sources_searched"], :>, 0
    assert_equal 1, result["metadata"]["documents_fetched"]
    assert result["metadata"]["generated_at"].present?
  end

  # 缓存分别在 SerperSearch / PageFetcher / Researcher 里，所以这里用真的搜索与抓取对象
  # （只把它们的网络层打桩），否则缓存根本没参与，测出来的「命中」是假的。
  test "重跑时搜索 / 抓取 / LLM 全部命中缓存，不再调用外部服务" do
    conn, requests = fake_serper_connection(status: 200, body: {
      "organic" => [ { "title" => "搜索结果标题", "link" => "https://a.com/1", "snippet" => "摘要" } ]
    }.to_json)
    search = serper_search(conn)
    fetch_count = 0
    llm = fake_object({
      generate_json: lambda do |_prompt|
        { "awards" => [ { "rank" => "一等奖", "people" => [ { "name" => "张三" } ] } ] }
      end
    })

    html = "<html><head><title>页面标题</title></head><body>#{'正文' * 200}</body></html>"
    with_fake_website_fetcher(->(url) { fetch_count += 1; WebsiteCrawler::FetchResult.success(url: url, html: html) }) do
      first = run_research(search: search, pages: real_page_fetcher, llm: llm)
      counts = [ requests.length, fetch_count, llm.calls.length ]

      second = run_research(search: search, pages: real_page_fetcher, llm: llm)

      assert_equal counts, [ requests.length, fetch_count, llm.calls.length ], "第二次运行不该再打外部服务"
      # metadata 里有 generated_at 与累计的缓存统计，每次运行都不同，只比结果本身
      assert_equal first.except("metadata"), second.except("metadata"), "缓存命中时结果应完全一致"
      assert_operator second["metadata"]["cache"]["search"]["hit"], :>, 0
      assert_operator second["metadata"]["cache"]["document"]["hit"], :>, 0
      assert_operator second["metadata"]["cache"]["llm"]["hit"], :>, 0
      assert_equal first["metadata"]["documents_fetched"], second["metadata"]["documents_fetched"]
    end
  end

  test "正文过短的文档会被丢弃并记入失败清单" do
    search = fake_object({
      search: ->(_query, limit: 10) { [ { "title" => "标题", "url" => "https://a.com/shell", "snippet" => "摘要" } ] }
    })
    pages = fake_page_fetcher(->(url) { { "url" => url, "title" => "空壳", "text" => "短", "kind" => "success" } })
    llm = fake_object({ generate_json: ->(_prompt) { { "awards" => [] } } })

    researcher = EventResearch::Researcher.new(
      event: "测试大会", search: search, pages: pages, llm: llm,
      cache: @cache, reporter: @reporter
    )
    result = researcher.run

    assert_equal 0, result["metadata"]["documents_fetched"]
    assert_equal [ "too_short" ], result["metadata"]["fetch_failures"].map { |failure| failure["kind"] }.uniq
  end

  test "失败清单截断到 MAX_FETCH_FAILURES 条，但总数如实统计" do
    pages = fake_page_fetcher(->(url) { { "url" => url, "kind" => "timeout", "error" => "超时" } })
    researcher = EventResearch::Researcher.new(
      event: "测试大会", search: nil, pages: pages, llm: nil,
      cache: @cache, reporter: @reporter
    )
    results = Array.new(3) { |i| { "url" => "https://a.com/#{i}", "title" => "标题" } }

    stub_const_value(EventResearch, "MAX_FETCH_FAILURES", 1) do
      assert_empty researcher.send(:fetch_documents, results, phase: "event")
    end

    metadata = researcher.send(:metadata, results, [], [])
    assert_equal 3, metadata["fetch_failure_count"], "总数不该被截断"
    assert_equal 1, metadata["fetch_failures"].length
  end

  private

  def success_page(url)
    { "url" => url, "title" => "页面标题", "text" => "正文" * 200, "kind" => "success" }
  end

  def fake_llm
    fake_object({
      generate_json: lambda do |_prompt|
        { "awards" => [ { "rank" => "一等奖", "people" => [ { "name" => "张三" } ] } ] }
      end
    })
  end

  def build_researcher(tianyancha: nil, **config)
    EventResearch::Researcher.new(
      event: "测试大会", search: nil, pages: nil, llm: nil, tianyancha: tianyancha,
      cache: @cache, reporter: @reporter, **config
    )
  end

  def run_research(search:, pages:, llm:, tianyancha: nil, **config)
    EventResearch::Researcher.new(
      event: "测试大会", search: search, pages: pages, llm: llm, tianyancha: tianyancha,
      cache: @cache, reporter: @reporter, **config
    ).run
  end

  # 记录每条查询的搜索替身（queries 可断言），每次返回同一批结果
  def recording_search(results: [ { "title" => "搜索结果标题", "url" => "https://a.com/1", "snippet" => "摘要" } ])
    queries = []
    search = Object.new
    search.define_singleton_method(:search) do |query, limit: 10|
      queries << query
      results
    end
    search.define_singleton_method(:queries) { queries }
    search
  end

  # 一个人 + 一家公司的结果骨架，天眼查相关测试共用
  def company_result(person_name, extra_employment: [])
    {
      "awards" => [ {
        "project" => { "organization" => "中航重机股份有限公司" },
        "people" => [ { "name" => person_name,
                        "employment" => [ { "organization" => "中航重机股份有限公司" } ] + extra_employment } ]
      } ]
    }
  end

  # 跑一遍「天眼查补全 → 回填」，返回回填后的结果
  def tianyancha_research_result(person_name: "崔龙", body: nil)
    connection = fake_tianyancha_connection(body: (body || tianyancha_body).to_json).first
    researcher = build_researcher(tianyancha: tianyancha_client(connection))
    result = company_result(person_name)

    researcher.send(:enrich_companies, result)
    researcher.send(:attach_tianyancha_links, result)
    result["metadata"] = researcher.send(:metadata, [], [], [])
    result
  end

  # 搜索 / 抓取 / LLM 三个替身，各自记录被调用的次数（calls）
  def fake_research_dependencies
    search = recording_search
    pages = fake_page_fetcher(->(url) { success_page(url) })
    llm = fake_llm

    [ search, pages, llm ]
  end

  # 只实现指定方法的替身（项目没有 mocha）；每次调用都记进 calls，便于断言「没有再打外部服务」
  def fake_object(methods, calls: [])
    object = Object.new
    methods.each do |name, body|
      object.define_singleton_method(name) do |*args, **kwargs, &block|
        calls << name
        body.call(*args, **kwargs, &block)
      end
    end
    object.define_singleton_method(:calls) { calls }
    object
  end

  # 真的 PageFetcher（缓存逻辑参与其中），只有它内部的 WebsiteCrawler::Fetcher 被 with_fake_website_fetcher 打桩
  def real_page_fetcher
    EventResearch::PageFetcher.new(cache: @cache, reporter: @reporter)
  end

  # PageFetcher 替身：抓取入口有 fetch / fetch_many 两个，替身都要实现
  # （fetch_many 与真实现一样按输入顺序返回，所以这里的顺序串行等价）
  def fake_page_fetcher(fetch_proc)
    fake_object({
      fetch: fetch_proc,
      fetch_many: ->(urls, concurrency: nil) { urls.map { |url| fetch_proc.call(url) } }
    })
  end

  def serper_search(connection, api_key: "test-key")
    EventResearch::SerperSearch.new(api_key: api_key, cache: @cache, reporter: @reporter).tap do |search|
      search.define_singleton_method(:connection) { connection }
    end
  end

  def tavily_search(connection, api_key: "test-key")
    EventResearch::TavilySearch.new(api_key: api_key, cache: @cache, reporter: @reporter).tap do |search|
      search.define_singleton_method(:connection) { connection }
    end
  end

  def fake_tavily_connection(status:, body:)
    response = Struct.new(:status, :body) do
      def success?
        status.between?(200, 299)
      end
    end.new(status, body)

    requests = []
    connection = Object.new
    connection.define_singleton_method(:post) do |*_args, &block|
      request = Faraday::Request.create(:post)
      request.params = Faraday::Utils::ParamsHash.new
      request.headers = Faraday::Utils::Headers.new
      request.options = Faraday::RequestOptions.new
      block&.call(request)
      requests << request
      response
    end

    [ connection, requests ]
  end

  # Serper 的假连接：记录每个请求（含 headers/body），返回给定响应
  def fake_serper_connection(status:, body:)
    response = Struct.new(:status, :body) do
      def success?
        status.between?(200, 299)
      end
    end.new(status, body)

    requests = []
    connection = Object.new
    connection.define_singleton_method(:post) do |*_args, &block|
      request = Faraday::Request.create(:post)
      request.params = Faraday::Utils::ParamsHash.new
      request.headers = Faraday::Utils::Headers.new
      request.options = Faraday::RequestOptions.new
      block&.call(request)
      requests << request
      response
    end

    [ connection, requests ]
  end

  # 天眼查替身客户端：连接换成假连接，其余（缓存 / 归一化 / 错误分流）走真实现
  def tianyancha_client(connection, api_key: "test-token", max_queries: nil)
    options = { api_key: api_key, cache: @cache, reporter: @reporter }
    options[:max_queries] = max_queries if max_queries

    EventResearch::TianyanchaClient.new(**options).tap do |client|
      client.define_singleton_method(:connection) { connection }
    end
  end

  # 天眼查的假连接：记录每个请求（含 headers/params），返回给定响应
  def fake_tianyancha_connection(status: 200, body:)
    response = Struct.new(:status, :body) do
      def success?
        status.between?(200, 299)
      end
    end.new(status, body)

    requests = []
    connection = Object.new
    connection.define_singleton_method(:get) do |*_args, &block|
      request = Faraday::Request.create(:get)
      request.params = Faraday::Utils::ParamsHash.new
      request.headers = Faraday::Utils::Headers.new
      request.options = Faraday::RequestOptions.new
      block&.call(request)
      requests << request
      response
    end

    [ connection, requests ]
  end

  # 中航重机股份有限公司的响应（取自 docs/tianyancha_api.md 的真实返回，删到只留用得上的字段）
  def tianyancha_body
    {
      "result" => {
        "name" => "中航重机股份有限公司",
        "creditCode" => "91520000214434146R",
        "legalPersonName" => "姬苏春",
        "regCapital" => "77800.32万人民币",
        "estiblishTime" => 847_900_800_000,
        "regStatus" => "存续",
        "companyOrgType" => "其他股份有限公司(上市)",
        "industry" => "汽车制造业",
        "regLocation" => "贵州双龙航空港经济区机场路9号太升国际A栋3单元5层",
        "businessScope" => "股权投资及经营管理；军民共用液压件",
        "phoneNumber" => "0851-88600765",
        "emailList" => [ "zhzjgk@163.com", "zhzj@avic.com" ],
        "websiteList" => "www.hm.avic.com",
        "tags" => "存续;曾用名;A股",
        "id" => 11_684_584,
        "staffList" => {
          "result" => [
            { "name" => "姬苏春", "id" => 1_875_401_345, "type" => 2, "typeJoin" => [ "董事长" ] },
            { "name" => "崔龙", "id" => 1_905_833_345, "type" => 2, "typeJoin" => [ "监事" ] }
          ],
          "total" => 2
        }
      },
      "reason" => "ok",
      "error_code" => 0
    }
  end

  # 替换 WebsiteCrawler::Fetcher.new，返回只实现 fetch 的替身
  def with_fake_website_fetcher(fetcher_proc)
    fake = fake_object({ fetch: fetcher_proc })
    stub_class_method(WebsiteCrawler::Fetcher, :new, ->(**_kwargs) { fake }) { yield }
  end

  # 在块内临时改写模块常量（stub_const 在这个代码库里还没有，用最朴素的换/还方式）
  def stub_const_value(owner, name, value)
    original = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name)
    owner.const_set(name, original)
  end

  def cache_path(namespace, key)
    File.join(@tmpdir, "cache", namespace, "#{Digest::SHA256.hexdigest(key)}.json")
  end

  def expire_cache_entry(namespace, key)
    path = cache_path(namespace, key)
    entry = JSON.parse(File.read(path))
    entry["cached_at"] = 2.days.ago.iso8601
    File.write(path, JSON.generate(entry))
  end
end
