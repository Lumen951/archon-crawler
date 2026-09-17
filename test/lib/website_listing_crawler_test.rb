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

    stub_class_method(WebsiteCrawler::ListingCrawler, :new, -> { runner }) do
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

    stub_class_method(WebsiteCrawler::ListingCrawler, :new, -> { runner }) do
      WebsiteCrawler.crawl_account(@account, task, article_concurrency: 1, max_pages: 1)
    end

    task_account = task.crawl_task_accounts.find_by!(account: @account)
    assert task_account.failed?
    assert_match "入口不可用", task_account.error_message
    assert_equal "error", @account.reload.last_check_status
  end

  private

  def listing_crawler(fetcher)
    WebsiteCrawler::ListingCrawler.new(
      fetcher: fetcher,
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
