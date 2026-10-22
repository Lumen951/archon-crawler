require "test_helper"
require "webmock/minitest"

class PaperAuthorDiscoveryTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email_address: "discovery@example.test", password: "password123", email_confirmed_at: Time.current)
    paper = Paper.create!(title: "Seed")
    author = PaperAuthor.create!(display_name: "Example Author", provider: "arxiv")
    paper.authorships.create!(paper_author: author, display_name: author.display_name, position: 0)
    @subscription = user.paper_subscriptions.create!(paper_author: author, seed_paper: paper,
      display_name: author.display_name, name_variants: [ author.display_name ])
    @run = @subscription.sync_runs.create!(run_token: "test", cutoff_at: Time.utc(2026, 10, 22),
      name_variants: @subscription.name_variants)
  end

  test "queries a fixed full history window and preserves middle author position" do
    stub_request(:get, "https://export.arxiv.org/api/query").with(query: {
      search_query: '(au:"Example Author") AND submittedDate:[199101010000 TO 202610220000]',
      start: "0", max_results: "50", sortBy: "submittedDate", sortOrder: "ascending"
    }).to_return(body: feed)
    discovery = PaperAuthorDiscovery.new(@run)
    page = discovery.fetch_page
    PaperSource.transaction { discovery.save_page!(page) }
    match = @subscription.matches.sole
    assert match.pending?
    assert_equal [ 1 ], match.evidence["positions"]
    assert_equal 3, match.evidence["author_count"]
    assert_equal [ 1, 2 ], match.paper_source.paper.authorships.pluck(:position)
    assert_equal [ "", "Example Author", "Last Author" ], match.evidence["authors"]
    assert_equal 1, page.total
  end

  test "repeated search preserves identity decisions and reuses paper metadata" do
    stub_feed
    discovery = PaperAuthorDiscovery.new(@run)
    page = discovery.fetch_page
    PaperSource.transaction { discovery.save_page!(page) }
    match = @subscription.matches.sole
    match.update!(status: :excluded, reviewed_at: Time.current)
    second_run = @subscription.sync_runs.create!(run_token: "next", cutoff_at: @run.cutoff_at,
      name_variants: @run.name_variants)
    assert_no_difference [ "Paper.count", "PaperSubscriptionMatch.count" ] do
      PaperSource.transaction { PaperAuthorDiscovery.new(second_run).save_page!(page) }
    end
    assert match.reload.excluded?
    assert_raises(PaperImporter::FetchError) do
      PaperSource.transaction { PaperAuthorDiscovery.new(second_run).save_page!(page) }
    end
  end

  test "broad API name matches remain candidates without inventing identity" do
    stub_feed(feed.sub("Example Author</name>", "E. Author</name>"))
    discovery = PaperAuthorDiscovery.new(@run)
    PaperSource.transaction { discovery.save_page!(discovery.fetch_page) }
    match = @subscription.matches.sole
    assert_empty match.evidence["positions"]
    assert match.pending?
    refute_includes match.paper_source.paper.authors.ids, @subscription.paper_author_id
  end

  test "malformed totals offsets entries and changed totals fail explicitly" do
    [
      feed.sub("<os:totalResults>1", "<os:totalResults>oops"),
      feed.sub("<os:startIndex>0", "<os:startIndex>50"),
      feed.sub("<os:totalResults>1", "<os:totalResults>30001"),
      feed.sub("http://arxiv.org/abs/2401.00001v1", "http://arxiv.org/api/errors"),
      "<feed>"
    ].each do |body|
      stub_feed(body)
      assert_raises(PaperImporter::FetchError) { PaperAuthorDiscovery.new(@run).fetch_page }
    end
    @run.update!(total_count: 2)
    stub_feed
    assert_raises(PaperImporter::FetchError) { PaperAuthorDiscovery.new(@run).fetch_page }
  end

  test "empty incomplete pages fail while genuine zero results are valid" do
    body = feed.sub(/<entry>.*?<\/entry>/m, "")
    stub_feed(body)
    assert_raises(PaperImporter::FetchError) { PaperAuthorDiscovery.new(@run).fetch_page }
    stub_feed(body.sub("<os:totalResults>1", "<os:totalResults>0"))
    page = PaperAuthorDiscovery.new(@run).fetch_page
    assert_empty page.results
    assert_equal 0, page.total
  end

  test "timeouts and rate limits are retryable without records" do
    stub_request(:get, /export\.arxiv\.org/).to_timeout
    assert_raises(PaperImporter::TemporaryError) { PaperAuthorDiscovery.new(@run).fetch_page }
    stub_request(:get, /export\.arxiv\.org/).to_return(status: 429, headers: { "Retry-After" => "600" })
    error = assert_raises(PaperImporter::TemporaryError) { PaperAuthorDiscovery.new(@run).fetch_page }
    assert_equal 600, error.retry_after
    assert_empty @subscription.matches
  end

  test "invalid later entry rolls back the entire page" do
    stub_feed
    discovery = PaperAuthorDiscovery.new(@run)
    result = discovery.fetch_page.results.first
    invalid = result.with(external_id: "2401.00002", title: "")
    assert_no_difference [ "Paper.count", "PaperSubscriptionMatch.count" ] do
      assert_raises(PaperImporter::FetchError) do
        PaperSource.transaction { discovery.save_page!(PaperAuthorDiscovery::Page.new([ result, invalid ], 2)) }
      end
    end
  end

  private

  def stub_feed(body = feed)
    stub_request(:get, /export\.arxiv\.org/).to_return(body: body)
  end

  def feed
    <<~XML
      <feed xmlns="http://www.w3.org/2005/Atom" xmlns:os="http://a9.com/-/spec/opensearch/1.1/">
        <os:totalResults>1</os:totalResults><os:startIndex>0</os:startIndex>
        <entry><id>http://arxiv.org/abs/2401.00001v1</id><title>Candidate</title>
          <summary>Summary</summary><published>2024-01-01T00:00:00Z</published><updated>2024-01-01T00:00:00Z</updated>
          <author><name></name></author><author><name>Example Author</name></author><author><name>Last Author</name></author>
        </entry>
      </feed>
    XML
  end
end
