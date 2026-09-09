require "test_helper"
require "website_crawler"

class ArticleSynchronizerTest < ActiveSupport::TestCase
  def build_account(fakeid: "example.com")
    WebsiteAccount.create!(fakeid: fakeid, nickname: "Example", metadata: { url: "https://example.com" })
  end

  def build_page(account, url: "https://example.com/blog", page_type: "blog")
    account.monitor_pages.create!(url: url, title: "Blog", page_type: page_type)
  end

  def page_html(title)
    <<~HTML
      <html><head><title>#{title}</title></head>
      <body><article><h1>#{title}</h1><p>#{'足够长的正文内容，用于通过最小长度门槛，确保文章正文被保留。' * 5}</p></article></body></html>
    HTML
  end

  # Deterministic analyzer stand-in: no LLM call, but the real line diff so
  # diff_added / diff_removed stay meaningful.
  class StubAnalyzer
    def analyze(page:, previous_content:, current_content:, diff: nil, crawl_task: nil)
      diff ||= WebsiteCrawler::Analyzer.new.diff(previous_content, current_content)
      [{
        "summary" => "页面发生变化",
        "importance" => 5,
        "relevance" => 5,
        "change_type" => "content_updated",
        "changes" => ["一处变化"],
        "entities" => []
      }, :completed]
    end

    def diff(previous, current)
      WebsiteCrawler::Analyzer.new.diff(previous, current)
    end
  end

  # Analyzer stand-in that records every call so tests can assert the analyzer
  # is only invoked when a change is actually persisted.
  class RecordingAnalyzer < StubAnalyzer
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def analyze(page:, previous_content:, current_content:, diff: nil, crawl_task: nil)
      @calls += 1
      super
    end
  end

  # Content extractor that behaves normally for the change-detection pass but
  # blows up while extracting the article body — used to prove a failure part
  # way through a capture rolls back the version already written.
  class ExplodingArticleExtractor
    def initialize
      @inner = WebsiteCrawler::Extractor.new
    end

    def extract(html, base_url = nil)
      @inner.extract(html, base_url)
    end

    def extract_article(_html, _base_url = nil)
      raise "article extraction exploded"
    end
  end

  def synchronizer
    WebsiteCrawler::ArticleSynchronizer.new(
      content_extractor: WebsiteCrawler::Extractor.new,
      analyzer: StubAnalyzer.new
    )
  end

  test "first capture stores a baseline version and article, but no change record" do
    account = build_account
    page = build_page(account)

    result = synchronizer.capture_page(account: account, page: page, html: page_html("First Post"), http_status: 200)

    assert result[:changed]
    assert_equal 1, page.monitor_page_versions.count
    assert_equal page.monitor_page_versions.first.id, page.reload.current_version_id
    assert_nil MonitorChange.find_by(monitor_page: page)

    article = Article.find_by(url: page.url)
    assert_equal account, article.account
    assert_equal "First Post", article.title
    assert article.content_html.present?
    assert article.content_markdown.present?

    assert_equal "success", page.reload.last_status
    assert page.last_checked_at.present?
    assert_equal "http", page.fetched_via
  end

  test "unchanged content stores no new version or change" do
    account = build_account
    page = build_page(account)
    synchronizer.capture_page(account: account, page: page, html: page_html("Same Post"))

    result = nil
    assert_no_difference -> { MonitorPageVersion.count } do
      result = synchronizer.capture_page(account: account, page: page, html: page_html("Same Post"))
    end

    refute result[:changed]
    assert_nil MonitorChange.find_by(monitor_page: page)
    assert_equal 1, page.reload.versions_count
    assert_equal "success", page.reload.last_status
  end

  test "changed content stores a version, records the change and refreshes the article" do
    account = build_account
    page = build_page(account)
    synchronizer.capture_page(account: account, page: page, html: page_html("Old Title"))

    result = synchronizer.capture_page(account: account, page: page, html: page_html("New Title"))

    assert result[:changed]
    assert_equal 2, page.reload.versions_count
    assert page.last_changed_at.present?

    change = MonitorChange.find_by(monitor_page: page)
    assert_equal account, change.account
    assert_equal "页面发生变化", change.summary
    assert_equal 5, change.importance
    assert_equal "completed", change.analysis_status
    assert_equal page.reload.current_version_id, change.monitor_page_version_id

    assert_equal "New Title", Article.find_by(url: page.url).title
  end

  test "a page whose body is too short syncs no article but still stores a version" do
    account = build_account
    page = build_page(account)
    html = "<html><head><title>Short</title></head><body><article><p>太短</p></article></body></html>"

    result = synchronizer.capture_page(account: account, page: page, html: html)

    assert result[:changed]
    assert_equal 1, page.monitor_page_versions.count
    assert_nil Article.find_by(url: page.url)
    assert_equal "success", page.reload.last_status
  end

  test "never overwrites another account's article" do
    account = build_account
    other = build_account(fakeid: "other.example.com")
    page = build_page(account)
    Article.create!(account: other, title: "Owned", url: page.url, content_html: "x", content_markdown: "x")

    synchronizer.capture_page(account: account, page: page, html: page_html("New Post"))

    article = Article.find_by(url: page.url)
    assert_equal other, article.account
    assert_equal "Owned", article.title
  end

  test "a failure part way through a capture rolls back the version and status" do
    account = build_account
    page = build_page(account)
    sync = WebsiteCrawler::ArticleSynchronizer.new(
      content_extractor: ExplodingArticleExtractor.new,
      analyzer: StubAnalyzer.new
    )

    assert_raises(RuntimeError) do
      sync.capture_page(account: account, page: page, html: page_html("First Post"))
    end

    assert_equal 0, page.reload.monitor_page_versions.count
    assert_nil page.current_version_id
    assert_equal "Blog", page.title # in-memory title assignment was rolled back too
    assert_nil page.last_status
    assert_nil Article.find_by(url: page.url)
  end

  test "runs the analyzer once per persisted change and not for baselines or unchanged captures" do
    account = build_account
    page = build_page(account)
    analyzer = RecordingAnalyzer.new
    sync = WebsiteCrawler::ArticleSynchronizer.new(
      content_extractor: WebsiteCrawler::Extractor.new,
      analyzer: analyzer
    )

    sync.capture_page(account: account, page: page, html: page_html("First Post")) # baseline: no analyzer call
    assert_equal 0, analyzer.calls

    sync.capture_page(account: account, page: page, html: page_html("Second Post")) # one change, one call
    assert_equal 1, analyzer.calls

    sync.capture_page(account: account, page: page, html: page_html("Second Post")) # unchanged: no call
    assert_equal 1, analyzer.calls
  end
end
