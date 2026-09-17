require "test_helper"

class Website::ListingRuleGeneratorTest < ActiveSupport::TestCase
  class FakeFetcher
    def initialize(results)
      @results = results
    end

    def fetch(url)
      @results.fetch(url) do
        WebsiteCrawler::FetchResult.failure(url: url, kind: :unsupported, error: "not configured in fake fetcher")
      end
    end
  end

  class FakeLlm
    def initialize(*proposals)
      @proposals = proposals
    end

    def generate_json(_prompt)
      @proposals.shift
    end
  end

  def setup
    @account = WebsiteAccount.create!(
      fakeid: "example.com",
      nickname: "Example",
      metadata: { "url" => "https://example.com/events" },
      crawl_rule: { "mode" => "listing" }
    )
  end

  test "generates and verifies a rule from direct HTML" do
    html = listing_html
    generator = Website::ListingRuleGenerator.new(
      fetcher: FakeFetcher.new(results_for(html)),
      renderer: FakeFetcher.new({}),
      llm: FakeLlm.new(valid_proposal, valid_detail_proposal)
    )

    rule = generator.generate(@account)

    assert_equal "listing", rule["mode"]
    assert_equal [ @account.url ], rule["entry_urls"]
    assert_equal ".event-card", rule["item_selector"]
    assert_equal "#content", rule.dig("detail", "content_selector")
    assert_equal 5, rule.dig("limits", "max_items")
    assert_equal 10, rule.dig("limits", "interval_seconds")
  end

  test "uses rendered HTML when direct HTML cannot verify a proposal" do
    direct = WebsiteCrawler::FetchResult.success(url: @account.url, html: "<div id=app></div>")
    generator = Website::ListingRuleGenerator.new(
      fetcher: FakeFetcher.new({ @account.url => direct }),
      renderer: FakeFetcher.new(results_for(listing_html)),
      llm: FakeLlm.new(valid_proposal, valid_proposal, valid_detail_proposal)
    )

    rule = generator.generate(@account)

    assert_equal ".event-card", rule["item_selector"]
  end

  test "raises when neither source yields a verified rule" do
    empty = WebsiteCrawler::FetchResult.success(url: @account.url, html: "<div id=app></div>")
    generator = Website::ListingRuleGenerator.new(
      fetcher: FakeFetcher.new({ @account.url => empty }),
      renderer: FakeFetcher.new({ @account.url => empty }),
      llm: FakeLlm.new(valid_proposal, valid_proposal)
    )

    assert_raises(Website::ListingRuleGenerator::GenerationError) { generator.generate(@account) }
  end

  test "rejects a listing rule when its detail selector cannot extract readable content" do
    generator = Website::ListingRuleGenerator.new(
      fetcher: FakeFetcher.new(results_for(listing_html)),
      renderer: FakeFetcher.new({}),
      llm: FakeLlm.new(valid_proposal, { "content_selector" => "#missing" })
    )

    assert_raises(Website::ListingRuleGenerator::GenerationError) { generator.generate(@account) }
  end

  private

  def valid_proposal
    {
      "item_selector" => ".event-card",
      "url" => { "selector" => "a.title", "attribute" => "href" },
      "title" => { "selector" => "a.title" },
      "limits" => { "max_items" => 20, "interval_seconds" => 1 },
      "url_policy" => { "allow_path_prefixes" => [ "/events/" ] }
    }
  end

  def valid_detail_proposal
    { "content_selector" => "#content" }
  end

  def results_for(listing)
    {
      @account.url => WebsiteCrawler::FetchResult.success(url: @account.url, html: listing),
      "https://example.com/events/one" => WebsiteCrawler::FetchResult.success(url: "https://example.com/events/one", html: detail_html("One")),
      "https://example.com/events/two" => WebsiteCrawler::FetchResult.success(url: "https://example.com/events/two", html: detail_html("Two"))
    }
  end

  def listing_html
    <<~HTML
      <div class="event-card"><a class="title" href="/events/one">First event</a></div>
      <div class="event-card"><a class="title" href="/events/two">Second event</a></div>
    HTML
  end

  def detail_html(name)
    <<~HTML
      <html><body><script type="x-template" id="content">
        <p>#{name} #{'meaningful event content ' * 20}</p>
        <img src="/poster.jpg">
      </script></body></html>
    HTML
  end
end
