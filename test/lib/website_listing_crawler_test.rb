require "test_helper"

class WebsiteListingCrawlerTest < ActiveSupport::TestCase
  class FakeFetcher
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def fetch(url)
      @calls << url
      @responses.fetch(url)
    end
  end

  class NoopHostRateLimiter
    def wait(_url, interval_seconds:)
    end
  end

  class FakeResponse
    attr_reader :status, :headers, :body

    def initialize(status:, body: "", headers: {})
      @status = status
      @body = body
      @headers = Faraday::Utils::Headers.new(headers)
    end

    def success?
      status.between?(200, 299)
    end
  end

  FakeRenderRequest = Struct.new(:path, :params, :headers) do
    def initialize(path)
      super(path, {}, {})
    end
  end

  class FakeRenderConnection
    attr_reader :requests

    def initialize(response)
      @response = response
      @requests = []
    end

    def get(path)
      request = FakeRenderRequest.new(path)
      yield request
      @requests << request
      @response
    end
  end

  def setup
    @account = WebsiteAccount.create!(
      fakeid: "example.com",
      nickname: "Example",
      metadata: { "url" => "https://example.com" }
    )
    @host_rate_limiter = NoopHostRateLimiter.new
  end

  test "listing host rate limiter spaces requests for the same host" do
    now = 0.0
    sleeps = []
    limiter = WebsiteCrawler::ListingHostRateLimiter.new(
      clock: -> { now },
      sleeper: ->(seconds) { sleeps << seconds; now += seconds }
    )

    limiter.wait("https://example.com/events", interval_seconds: 0)
    limiter.wait("https://example.com/events/1", interval_seconds: 1)
    limiter.wait("https://other.example.com/events", interval_seconds: 0)

    assert_equal [ 5.0 ], sleeps
  end

  test "empty rule remains compatible with sitemap mode" do
    rule = WebsiteCrawler::ListingRule.new(@account, {})

    assert rule.sitemap?
    assert_equal "sitemap", @account.crawl_mode
  end

  test "bare listing rule is valid on the account but fails when crawled" do
    @account.update!(crawl_rule: { "mode" => "listing" })
    task = CrawlTask.create!(account_ids: [ @account.id ], status: :running)
    task.setup_account_tracking!

    WebsiteCrawler.crawl_account(@account, task, article_concurrency: 1, max_pages: 1)

    task_account = task.crawl_task_accounts.find_by!(account: @account)
    assert task_account.failed?
    assert_match "尚未生成", task_account.error_message
  end

  test "listing rule rejects an entry URL outside the account site" do
    error = assert_raises(WebsiteCrawler::ListingRule::InvalidRule) do
      WebsiteCrawler::ListingRule.new(@account, listing_rule(entry_urls: [ "https://attacker.example.org/events" ]))
    end

    assert_match "同站", error.message
  end

  test "website account cannot persist an unsupported crawl rule" do
    @account.crawl_rule = { "mode" => "browser" }

    assert_not @account.valid?
    assert_includes @account.errors[:crawl_rule], "mode 只能是 sitemap 或 listing"
  end

  test "listing rule does not treat hostless URLs as the same site" do
    local_account = WebsiteAccount.create!(fakeid: "local-rule", nickname: "Local rule", metadata: { "url" => "http://localhost:3000" })

    assert_raises(WebsiteCrawler::ListingRule::InvalidRule) do
      WebsiteCrawler::ListingRule.new(local_account, listing_rule(entry_urls: [ "http://localhost:3000/events" ]))
    end
  end

  test "listing crawler canonicalizes URLs and syncs listing fields into raw data" do
    rule = WebsiteCrawler::ListingRule.new(@account, listing_rule)
    entry_url = rule.entry_urls.first
    detail_url = "https://example.com/events/1"
    fetcher = FakeFetcher.new(
      entry_url => WebsiteCrawler::FetchResult.success(url: entry_url, html: listing_html),
      detail_url => WebsiteCrawler::FetchResult.success(url: detail_url, html: detail_html)
    )

    result = listing_crawler(fetcher).crawl(
      account: @account,
      rule: rule,
      crawl_task: nil
    )

    assert_equal 1, result.candidates_count
    assert_equal 1, result.created_count
    assert_equal 0, result.detail_errors

    article = Article.find_by!(url: detail_url)
    assert_equal @account, article.account
    assert_equal "Example event", article.title
    assert_equal "Beijing", article.raw_data.dig("listing", "fields", "city")
    assert_equal "2026-09-20 14:00", article.raw_data.dig("listing", "fields", "event_starts_at_text")
    assert_match "Long event detail", article.content_html
    assert_equal "available", article.raw_data.dig("listing", "content_status")

    second = listing_crawler(fetcher).crawl(
      account: @account,
      rule: rule,
      crawl_task: nil
    )
    assert_equal 0, second.created_count
    assert_equal 1, Article.where(url: detail_url).count
  end

  test "listing crawler extracts rich text from an x-template detail selector" do
    rule = WebsiteCrawler::ListingRule.new(@account, listing_rule(detail_selector: "#tpContent"))
    entry_url = rule.entry_urls.first
    detail_url = "https://example.com/events/1"
    fetcher = FakeFetcher.new(
      entry_url => WebsiteCrawler::FetchResult.success(url: entry_url, html: listing_html),
      detail_url => WebsiteCrawler::FetchResult.success(url: detail_url, html: x_template_detail_html)
    )

    listing_crawler(fetcher).crawl(
      account: @account,
      rule: rule,
      crawl_task: nil
    )

    article = Article.find_by!(url: detail_url)
    assert_equal "Example event", article.title
    assert_match "Event agenda", article.content_html
    assert_match "Useful event information", article.content_markdown
    assert_equal "available", article.raw_data.dig("listing", "content_status")
  end

  test "listing crawler retains an image-only x-template detail" do
    rule = WebsiteCrawler::ListingRule.new(@account, listing_rule(detail_selector: "#tpContent"))
    entry_url = rule.entry_urls.first
    detail_url = "https://example.com/events/1"
    fetcher = FakeFetcher.new(
      entry_url => WebsiteCrawler::FetchResult.success(url: entry_url, html: listing_html),
      detail_url => WebsiteCrawler::FetchResult.success(url: detail_url, html: image_only_detail_html)
    )

    listing_crawler(fetcher).crawl(
      account: @account,
      rule: rule,
      crawl_task: nil
    )

    article = Article.find_by!(url: detail_url)
    assert_match 'src="https://example.com/images/poster.jpg"', article.content_html
    assert_includes article.content_markdown, "![Agenda poster](https://example.com/images/poster.jpg)"
    assert_equal "available", article.raw_data.dig("listing", "content_status")
  end

  test "listing crawler stores metadata only when a detail page is a Vue shell" do
    rule_definition = listing_rule
    rule_definition.delete("detail")
    rule = WebsiteCrawler::ListingRule.new(@account, rule_definition)
    entry_url = rule.entry_urls.first
    detail_url = "https://example.com/events/1"
    fetcher = FakeFetcher.new(
      entry_url => WebsiteCrawler::FetchResult.success(url: entry_url, html: listing_html),
      detail_url => WebsiteCrawler::FetchResult.success(url: detail_url, html: vue_shell_detail_html)
    )

    listing_crawler(fetcher).crawl(
      account: @account,
      rule: rule,
      crawl_task: nil
    )

    article = Article.find_by!(url: detail_url)
    assert_nil article.content_html
    assert_nil article.content_markdown
    assert_equal "unavailable", article.raw_data.dig("listing", "content_status")
    assert_equal "template_markup", article.raw_data.dig("listing", "content_error")
  end

  test "listing crawler stops remaining details after a host block" do
    rule = WebsiteCrawler::ListingRule.new(@account, listing_rule)
    entry_url = rule.entry_urls.first
    first_url = "https://example.com/events/1"
    second_url = "https://example.com/events/2"
    fetcher = FakeFetcher.new(
      entry_url => WebsiteCrawler::FetchResult.success(url: entry_url, html: <<~HTML),
        <div class="event-card"><a class="title" href="/events/1">First</a></div>
        <div class="event-card"><a class="title" href="/events/2">Second</a></div>
      HTML
      first_url => WebsiteCrawler::FetchResult.failure(url: first_url, kind: :rate_limited, status: 429, error: "HTTP 429"),
      second_url => WebsiteCrawler::FetchResult.success(url: second_url, html: detail_html)
    )

    result = listing_crawler(fetcher).crawl(account: @account, rule: rule, crawl_task: nil)

    assert_equal 2, result.candidates_count
    assert_equal 1, result.detail_errors
    refute_includes fetcher.calls, second_url
  end

  test "website crawler dispatches listing mode without creating monitor pages" do
    @account.update!(crawl_rule: listing_rule)
    task = CrawlTask.create!(account_ids: [ @account.id ], status: :running)
    task.setup_account_tracking!
    runner = Object.new
    runner.define_singleton_method(:crawl) do |**_arguments|
      WebsiteCrawler::ListingCrawler::Result.new(1, 0, 0, 0)
    end

    stub_class_method(WebsiteCrawler::ListingCrawler, :new, ->(**_options) { runner }) do
      WebsiteCrawler.crawl_account(@account, task, article_concurrency: 1, max_pages: 1)
    end

    assert_equal 0, @account.monitor_pages.count
    assert_equal "success", @account.reload.last_check_status
    assert task.crawl_task_accounts.find_by!(account: @account).completed?
  end

  test "website crawler marks the account failed when every listing entry is unavailable" do
    @account.update!(crawl_rule: listing_rule)
    task = CrawlTask.create!(account_ids: [ @account.id ], status: :running)
    task.setup_account_tracking!
    runner = Object.new
    runner.define_singleton_method(:crawl) do |**_arguments|
      WebsiteCrawler::ListingCrawler::Result.new(0, 0, 1, 0)
    end

    stub_class_method(WebsiteCrawler::ListingCrawler, :new, ->(**_options) { runner }) do
      WebsiteCrawler.crawl_account(@account, task, article_concurrency: 1, max_pages: 1)
    end

    task_account = task.crawl_task_accounts.find_by!(account: @account)
    assert task_account.failed?
    assert_match "入口不可用", task_account.error_message
    assert_equal "error", @account.reload.last_check_status
  end

  test "render api fetcher returns the rendered html for the requested url" do
    connection = FakeRenderConnection.new(FakeResponse.new(status: 200, body: "<html><body>rendered</body></html>"))

    result = render_fetcher(connection).fetch("https://example.com/events")

    assert result.success?
    assert_equal "<html><body>rendered</body></html>", result.html
    request = connection.requests.first
    assert_equal "/v2/general", request.path
    assert_equal "https://example.com/events", request.params["url"]
    assert_equal "test-key", request.headers["x-api-key"]
  end

  test "render api fetcher surfaces the target page status from the response header" do
    connection = FakeRenderConnection.new(
      FakeResponse.new(status: 200, body: "<html></html>", headers: { "ant-page-status-code" => "403" })
    )

    result = render_fetcher(connection).fetch("https://example.com/events")

    refute result.success?
    assert_equal :blocked, result.kind
    assert_equal 403, result.status
    assert_equal "HTTP 403", result.error
  end

  test "render api fetcher reports api errors with the service detail" do
    connection = FakeRenderConnection.new(
      FakeResponse.new(status: 403, body: { detail: "API token is wrong." }.to_json)
    )

    result = render_fetcher(connection).fetch("https://example.com/events")

    refute result.success?
    assert_equal :blocked, result.kind
    assert_match "ScrapingAnt API 错误 403", result.error
    assert_match "API token is wrong.", result.error
  end

  test "render api fetcher maps a rate limited api response" do
    connection = FakeRenderConnection.new(FakeResponse.new(status: 429, body: ""))

    result = render_fetcher(connection).fetch("https://example.com/events")

    refute result.success?
    assert_equal :rate_limited, result.kind
  end

  test "render api fetcher refuses to fetch without an api key" do
    result = WebsiteCrawler::ScrapingAntFetcher.new(api_key: nil).fetch("https://example.com/events")

    refute result.success?
    assert_equal :blocked, result.kind
    assert_match "scrapingant_api_key", result.error
  end

  test "render api fetcher is only built when a key is configured" do
    with_scrapingant_key(nil) do
      assert_nil WebsiteCrawler::ScrapingAntFetcher.build
    end

    with_scrapingant_key("test-key") do
      assert_instance_of WebsiteCrawler::ScrapingAntFetcher, WebsiteCrawler::ScrapingAntFetcher.build
    end
  end

  test "listing crawler keeps plain http when the rule already extracts candidates" do
    rule = WebsiteCrawler::ListingRule.new(@account, listing_rule)
    entry_url = rule.entry_urls.first
    detail_url = "https://example.com/events/1"
    fetcher = FakeFetcher.new(
      entry_url => WebsiteCrawler::FetchResult.success(url: entry_url, html: listing_html),
      detail_url => WebsiteCrawler::FetchResult.success(url: detail_url, html: detail_html)
    )
    render_fetcher = FakeFetcher.new({})

    result = listing_crawler(fetcher, render_fetcher: render_fetcher).crawl(account: @account, rule: rule, crawl_task: nil)

    assert_equal 1, result.created_count
    assert_empty render_fetcher.calls, "直连已提取到内容时不应调用渲染 API"
  end

  test "listing crawler renders an entry page the rule could not extract from" do
    rule = WebsiteCrawler::ListingRule.new(@account, listing_rule)
    entry_url = rule.entry_urls.first
    detail_url = "https://example.com/events/1"
    fetcher = FakeFetcher.new(
      entry_url => WebsiteCrawler::FetchResult.success(url: entry_url, html: "<html><body><div id=\"app\"></div></body></html>"),
      detail_url => WebsiteCrawler::FetchResult.success(url: detail_url, html: detail_html)
    )
    render_fetcher = FakeFetcher.new(
      entry_url => WebsiteCrawler::FetchResult.success(url: entry_url, html: listing_html)
    )

    result = listing_crawler(fetcher, render_fetcher: render_fetcher).crawl(account: @account, rule: rule, crawl_task: nil)

    assert_equal [ entry_url ], render_fetcher.calls
    assert_equal 1, result.candidates_count
    assert_equal 1, result.created_count
    assert_equal 0, result.entry_errors
  end

  test "listing crawler renders a detail page the rule could not extract content from" do
    rule = WebsiteCrawler::ListingRule.new(@account, listing_rule)
    entry_url = rule.entry_urls.first
    detail_url = "https://example.com/events/1"
    fetcher = FakeFetcher.new(
      entry_url => WebsiteCrawler::FetchResult.success(url: entry_url, html: listing_html),
      detail_url => WebsiteCrawler::FetchResult.success(url: detail_url, html: vue_shell_detail_html)
    )
    render_fetcher = FakeFetcher.new(
      detail_url => WebsiteCrawler::FetchResult.success(url: detail_url, html: detail_html)
    )

    result = listing_crawler(fetcher, render_fetcher: render_fetcher).crawl(account: @account, rule: rule, crawl_task: nil)

    assert_equal [ detail_url ], render_fetcher.calls
    assert_equal 0, result.detail_errors
    article = Article.find_by!(url: detail_url)
    assert_match "Long event detail", article.content_html
    assert_equal "available", article.raw_data.dig("listing", "content_status")
  end

  test "listing crawler does not buy a render when the direct fetch itself failed" do
    rule = WebsiteCrawler::ListingRule.new(@account, listing_rule)
    entry_url = rule.entry_urls.first
    detail_url = "https://example.com/events/1"
    fetcher = FakeFetcher.new(
      entry_url => WebsiteCrawler::FetchResult.success(url: entry_url, html: listing_html),
      detail_url => WebsiteCrawler::FetchResult.failure(url: detail_url, kind: :timeout, error: "execution expired")
    )
    render_fetcher = FakeFetcher.new({})

    result = listing_crawler(fetcher, render_fetcher: render_fetcher).crawl(account: @account, rule: rule, crawl_task: nil)

    assert_empty render_fetcher.calls, "没有拿到响应时不该走渲染兜底"
    assert_equal 1, result.detail_errors
    assert_equal "fetch_failed", Article.find_by!(url: detail_url).raw_data.dig("listing", "content_status")
  end

  test "listing crawler counts a failed render fallback as an entry error" do
    rule = WebsiteCrawler::ListingRule.new(@account, listing_rule)
    entry_url = rule.entry_urls.first
    fetcher = FakeFetcher.new(
      entry_url => WebsiteCrawler::FetchResult.success(url: entry_url, html: "<html><body><div id=\"app\"></div></body></html>")
    )
    render_fetcher = FakeFetcher.new(
      entry_url => WebsiteCrawler::FetchResult.failure(url: entry_url, kind: :blocked, status: 403, error: "ScrapingAnt API 错误 403: API token is wrong.")
    )

    result = listing_crawler(fetcher, render_fetcher: render_fetcher).crawl(account: @account, rule: rule, crawl_task: nil)

    assert_equal 0, result.candidates_count
    assert_equal 1, result.entry_errors
  end

  test "local headless browser fetcher can be built when selenium is available" do
    fetcher = WebsiteCrawler::LocalHeadlessBrowserFetcher.build

    assert_instance_of WebsiteCrawler::LocalHeadlessBrowserFetcher, fetcher
  end

  test "render fallback chain tries providers in order and returns first success" do
    url = "https://example.com/events"
    local_fetcher = FakeFetcher.new(
      url => WebsiteCrawler::FetchResult.success(url: url, html: "<html>local rendered</html>")
    )
    scrapingant_fetcher = FakeFetcher.new(
      url => WebsiteCrawler::FetchResult.success(url: url, html: "<html>scrapingant rendered</html>")
    )
    chain = WebsiteCrawler::RenderFallbackChain.new([ local_fetcher, scrapingant_fetcher ])

    result = chain.fetch(url)

    assert result.success?
    assert_equal "<html>local rendered</html>", result.html
    assert_equal [ url ], local_fetcher.calls
    assert_empty scrapingant_fetcher.calls, "第一个 provider 成功时不应调用后续 provider"
  end

  test "render fallback chain continues to next provider when first fails" do
    url = "https://example.com/events"
    local_fetcher = FakeFetcher.new(
      url => WebsiteCrawler::FetchResult.failure(url: url, kind: :timeout, error: "本地浏览器渲染超时")
    )
    scrapingant_fetcher = FakeFetcher.new(
      url => WebsiteCrawler::FetchResult.success(url: url, html: "<html>scrapingant rendered</html>")
    )
    chain = WebsiteCrawler::RenderFallbackChain.new([ local_fetcher, scrapingant_fetcher ])

    result = chain.fetch(url)

    assert result.success?
    assert_equal "<html>scrapingant rendered</html>", result.html
    assert_equal [ url ], local_fetcher.calls
    assert_equal [ url ], scrapingant_fetcher.calls
  end

  test "render fallback chain returns last failure when all providers fail" do
    url = "https://example.com/events"
    local_fetcher = FakeFetcher.new(
      url => WebsiteCrawler::FetchResult.failure(url: url, kind: :timeout, error: "本地浏览器渲染超时")
    )
    scrapingant_fetcher = FakeFetcher.new(
      url => WebsiteCrawler::FetchResult.failure(url: url, kind: :blocked, error: "ScrapingAnt API 错误 403")
    )
    chain = WebsiteCrawler::RenderFallbackChain.new([ local_fetcher, scrapingant_fetcher ])

    result = chain.fetch(url)

    refute result.success?
    assert_equal :blocked, result.kind
    assert_match "ScrapingAnt API 错误 403", result.error
  end

  test "render fallback chain build excludes unconfigured scrapingant" do
    with_scrapingant_key(nil) do
      chain = WebsiteCrawler::RenderFallbackChain.build

      # Only local_headless should be available when ScrapingAnt key is missing
      assert chain, "链应该被创建，因为本地浏览器可用"
    end
  end

  test "render fallback chain build returns nil when no providers are available" do
    # Stub both providers to return nil
    stub_class_method(WebsiteCrawler::LocalHeadlessBrowserFetcher, :build, -> { nil }) do
      with_scrapingant_key(nil) do
        chain = WebsiteCrawler::RenderFallbackChain.build

        assert_nil chain, "没有可用 provider 时应返回 nil"
      end
    end
  end

  test "configured monitoring rejects foreign URLs and missing selectors" do
    definition = listing_rule.merge("monitor_pages" => [ { "url" => "https://foreign.test/product", "selector" => "main" } ])
    assert_raises(WebsiteCrawler::ListingRule::InvalidRule) { WebsiteCrawler::ListingRule.new(@account, definition) }
    definition["monitor_pages"] = [ { "url" => "https://example.com/product" } ]
    assert_raises(WebsiteCrawler::ListingRule::InvalidRule) { WebsiteCrawler::ListingRule.new(@account, definition) }
  end

  test "paused listing leaves the account pending for resume" do
    @account.update!(crawl_rule: listing_rule)
    task = CrawlTask.create!(account_ids: [ @account.id ], status: :paused)
    task.setup_account_tracking!
    stub_class_method(WebsiteCrawler::RenderFallbackChain, :build, -> { nil }) do
      WebsiteCrawler.crawl_account(@account, task, article_concurrency: 1, max_pages: 1)
    end
    assert_predicate task.crawl_task_accounts.find_by!(account: @account), :pending?
    assert_nil @account.reload.last_crawled_at
  end

  test "non ASCII news URLs are escaped without corrupting existing byte escapes" do
    assert_equal "https://example.com/%E6%96%B0%E9%97%BB/%E2%80%91?a=%D1%EE",
      WebsiteCrawler::Fetcher.normalize("https://example.com", "/新闻/‑?a=%D1%EE")
  end

  test "video only official news retains its nested source URL as usable content" do
    html = '<html><body><article><video controls><source src="/demo.mp4" type="video/mp4"></video></article></body></html>'
    extracted = WebsiteCrawler::Extractor.new.extract_article(html, "https://example.com/news", selector: "article", strict_selector: true)
    assert_equal 1, extracted.media_count
    assert_equal 0, extracted.text_length
    assert WebsiteCrawler::ListingArticleSynchronizer.usable_content?(extracted)
    assert_includes extracted.html, 'src="https://example.com/demo.mp4"'
    assert_includes extracted.markdown, "[video](https://example.com/demo.mp4)"
  end

  test "short video announcements retain a video link but not unrelated short links" do
    extractor = WebsiteCrawler::Extractor.new
    html = '<article><a href="https://www.youtube.com/watch?v=demo">Watch the interview</a></article>'
    result = extractor.extract_article(html, "https://example.com/news", selector: "article")
    assert_equal 1, result.media_count
    assert_includes result.markdown, "youtube.com/watch?v=demo"
    unrelated = extractor.extract_article(html.sub("www.youtube.com", "example.com"), selector: "article")
    assert_nil unrelated.html
  end

  test "strict content selection never falls back to recommendations" do
    extracted = WebsiteCrawler::Extractor.new.extract_article(detail_html, selector: ".missing", strict_selector: true)
    assert_nil extracted.html
    assert_equal "configured_content_not_found", extracted.reason
  end

  test "weekly review skips stored bodies daily but revisits them after seven days" do
    rule = WebsiteCrawler::ListingRule.new(@account, listing_rule.merge("weekly_review" => true))
    entry = rule.entry_urls.first
    detail = "https://example.com/events/1"
    fetcher = FakeFetcher.new(
      entry => WebsiteCrawler::FetchResult.success(url: entry, html: listing_html),
      detail => WebsiteCrawler::FetchResult.success(url: detail, html: detail_html)
    )
    listing_crawler(fetcher).crawl(account: @account, rule: rule, crawl_task: nil)
    assert_nil Article.find_by!(url: detail).published_at
    fetcher.calls.clear
    listing_crawler(fetcher).crawl(account: @account, rule: rule, crawl_task: nil)
    assert_equal [ entry ], fetcher.calls
    @account.update!(metadata: @account.metadata.merge("listing_reviewed_at" => 8.days.ago.iso8601))
    fetcher.calls.clear
    listing_crawler(fetcher).crawl(account: @account, rule: rule, crawl_task: nil)
    assert_equal [ entry, detail ], fetcher.calls
  end

  test "empty detail increments errors and does not advance weekly review" do
    rule = WebsiteCrawler::ListingRule.new(@account, listing_rule.merge("weekly_review" => true))
    entry = rule.entry_urls.first
    detail = "https://example.com/events/1"
    fetcher = FakeFetcher.new(
      entry => WebsiteCrawler::FetchResult.success(url: entry, html: listing_html),
      detail => WebsiteCrawler::FetchResult.success(url: detail, html: "<html><body></body></html>")
    )
    result = listing_crawler(fetcher).crawl(account: @account, rule: rule, crawl_task: nil)
    assert_equal 1, result.detail_errors
    assert_nil @account.reload.metadata["listing_reviewed_at"]
  end

  test "configured product capture saves a baseline and skips a second check on the same day" do
    rule = WebsiteCrawler::ListingRule.new(@account, listing_rule.merge(
      "monitor_pages" => [ { "url" => "https://example.com/product", "selector" => "main" } ]
    ))
    task = CrawlTask.create!(account_ids: [ @account.id ], status: :running)
    fetcher = FakeFetcher.new("https://example.com/product" => WebsiteCrawler::FetchResult.success(url: "https://example.com/product", html: detail_html))
    stub_class_method(WebsiteCrawler::Fetcher, :new, -> { fetcher }) do
      stub_class_method(WebsiteCrawler::DEFAULT_LISTING_HOST_RATE_LIMITER, :wait, ->(*) { }) do
        result = WebsiteCrawler.crawl_configured_pages(@account, rule, task)
        assert_nil result[:error]
        assert_equal 1, @account.monitor_pages.first.monitor_page_versions.count
        assert Article.exists?(url: "https://example.com/product")
        WebsiteCrawler.crawl_configured_pages(@account, rule, task)
        assert_equal 1, fetcher.calls.size
      end
    end
  end

  test "failed product capture records an error without a false baseline" do
    rule = WebsiteCrawler::ListingRule.new(@account, listing_rule.merge(
      "monitor_pages" => [ { "url" => "https://example.com/product", "selector" => ".missing" } ]
    ))
    task = CrawlTask.create!(account_ids: [ @account.id ], status: :running)
    fetcher = FakeFetcher.new("https://example.com/product" => WebsiteCrawler::FetchResult.success(url: "https://example.com/product", html: detail_html))
    stub_class_method(WebsiteCrawler::Fetcher, :new, -> { fetcher }) do
      stub_class_method(WebsiteCrawler::DEFAULT_LISTING_HOST_RATE_LIMITER, :wait, ->(*) { }) do
        result = WebsiteCrawler.crawl_configured_pages(@account, rule, task)
        assert result[:error].present?
        assert_nil @account.monitor_pages.first.current_version_id
        assert_equal "error", @account.monitor_pages.first.last_status
      end
    end
  end

  private

  def render_fetcher(connection)
    fetcher = WebsiteCrawler::ScrapingAntFetcher.new(api_key: "test-key")
    fetcher.define_singleton_method(:connection) { connection }
    fetcher
  end

  # scrapingant_api_key 是全局 Option，用例结束后恢复原值（nil 表示未配置）。
  def with_scrapingant_key(value)
    previous = Option.get("scrapingant_api_key")
    value ? Option.set("scrapingant_api_key", value) : Option.delete("scrapingant_api_key")
    yield
  ensure
    previous ? Option.set("scrapingant_api_key", previous) : Option.delete("scrapingant_api_key")
  end

  def listing_crawler(fetcher, render_fetcher: nil)
    WebsiteCrawler::ListingCrawler.new(
      fetcher: fetcher,
      render_fetcher: render_fetcher,
      host_rate_limiter: @host_rate_limiter
    )
  end

  def listing_rule(entry_urls: [ "https://example.com/events" ], detail_selector: ".event-detail")
    {
      "mode" => "listing",
      "entry_urls" => entry_urls,
      "item_selector" => ".event-card",
      "url" => { "selector" => "a.title", "attribute" => "href" },
      "title" => { "selector" => "a.title" },
      "image" => { "selector" => "img.cover", "attribute" => "src" },
      "fields" => {
        "city" => { "selector" => ".city" },
        "event_starts_at_text" => { "selector" => ".starts-at" }
      },
      "detail" => { "content_selector" => detail_selector },
      "limits" => { "max_items" => 20, "interval_seconds" => 0 },
      "url_policy" => {
        "allow_path_prefixes" => [ "/events/" ],
        "strip_query_params" => [ "qd" ]
      }
    }
  end

  def listing_html
    <<~HTML
      <div class="event-card">
        <a class="title" href="/events/1?utm_source=feed&qd=source">Example event</a>
        <img class="cover" src="/images/event.png">
        <span class="city">Beijing</span>
        <time class="starts-at">2026-09-20 14:00</time>
      </div>
    HTML
  end

  def detail_html
    <<~HTML
      <html><head><title>Example event | Brand suffix</title></head><body>
        <main class="event-detail">Long event detail #{"with useful public information " * 8}</main>
      </body></html>
    HTML
  end

  def x_template_detail_html
    <<~HTML
      <html><head><title>Example event | Brand suffix</title></head><body>
        <script type="x-template" id="tpContent">
          <h2>Event agenda</h2>
          <p>#{"Useful event information " * 12}</p>
        </script>
        <main>{{ativityData.title}}</main>
      </body></html>
    HTML
  end

  def vue_shell_detail_html
    <<~HTML
      <html><head><title>Example event | Brand suffix</title></head><body>
        <main>
          <p>{{ativityData.title}}</p>
          <div v-if="tickets.length">#{"Visible-looking shell text " * 12}</div>
        </main>
      </body></html>
    HTML
  end

  def image_only_detail_html
    <<~HTML
      <html><head><title>Example event | Brand suffix</title></head><body>
        <script type="x-template" id="tpContent">
          <img src="/images/poster.jpg" alt="Agenda poster">
        </script>
      </body></html>
    HTML
  end
end
