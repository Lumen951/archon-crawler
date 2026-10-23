require "test_helper"
require "webmock/minitest"

class SemanticScholarClientTest < ActiveSupport::TestCase
  setup do
    @client = SemanticScholarClient.new(api_key: nil)
    @waits = []
    waits = @waits
    @client.define_singleton_method(:sleep) { |seconds| waits << seconds }
    @url = "#{SemanticScholarClient::BASE_URL}/paper/ARXIV:1706.03762"
    @payload = { paperId: "paper-1", title: "Example", externalIds: { ArXiv: "1706.03762" },
      authors: [ { authorId: "123", name: "Same Name" }, { authorId: nil, name: "Same Name" } ] }
  end

  test "normalizes versions and preserves ambiguous authors without verifying identity" do
    request = stub_request(:get, @url).with(query: { fields: "title,externalIds,authors" })
      .with { |req| !req.headers.key?("X-Api-Key") }.to_return(body: @payload.to_json)
    result = @client.paper("1706.03762v7")
    assert_equal "1706.03762", result["arxiv_id"]
    assert_equal [ "123", nil ], result["authors"].map { |author| author["author_id"] }
    assert_equal [ 0, 1 ], result["authors"].map { |author| author["position"] }
    assert_equal false, result["identity_verified"]
    assert Time.iso8601(result["observed_at"])
    assert_requested request, times: 1
  end

  test "author details preserve missing evidence and use optional key" do
    client = SemanticScholarClient.new(api_key: "synthetic-test-key")
    client.define_singleton_method(:sleep) { |_seconds| }
    stub_request(:get, "#{SemanticScholarClient::BASE_URL}/author/123").with(
      query: { fields: "name,affiliations,homepage,externalIds" }, headers: { "x-api-key" => "synthetic-test-key" }
    ).to_return(body: { authorId: "123", name: "Example" }.to_json)
    result = client.author("123")
    assert_nil result["affiliations"]
    assert_nil result["external_ids"]
    assert_equal false, result["identity_verified"]
  end

  test "rejects invalid identifiers before network requests" do
    assert_raises(ArgumentError) { @client.author("../secret") }
    assert_raises(PaperImporter::UnsupportedUrl) { @client.paper("bad-id") }
    assert_not_requested :get, /semanticscholar/
  end

  test "not found differs from malformed successful responses" do
    stub_paper(status: 404)
    assert_raises(SemanticScholarClient::NotFound) { @client.paper("1706.03762") }
    [ "not json", "[]", "{}" ].each do |body|
      stub_paper(body: body)
      assert_raises(SemanticScholarClient::FetchError) { @client.paper("1706.03762") }
    end
  end

  test "rejects mismatched paper and author identifiers" do
    @payload[:externalIds][:ArXiv] = "1234.56789"
    stub_paper(body: @payload.to_json)
    assert_raises(SemanticScholarClient::FetchError) { @client.paper("1706.03762") }
    stub_request(:get, /\/author\/123/).to_return(body: { authorId: "456" }.to_json)
    assert_raises(SemanticScholarClient::FetchError) { @client.author("123") }
  end

  test "retries rate limits at most twice and respects cooldown" do
    request = stub_paper(status: 429, headers: { "Retry-After" => "90" })
    error = assert_raises(SemanticScholarClient::TemporaryError) { @client.paper("1706.03762") }
    assert_equal 90, error.retry_after
    assert_equal [ 1, 90, 1, 120, 1 ], @waits
    assert_requested request, times: 3
  end

  test "long retry after returns control without retrying early" do
    request = stub_paper(status: 503, headers: { "Retry-After" => (Time.now + 600).httpdate })
    error = assert_raises(SemanticScholarClient::TemporaryError) { @client.paper("1706.03762") }
    assert_operator error.retry_after, :>=, 590
    assert_equal [ 1 ], @waits
    assert_requested request, times: 1
  end

  test "temporary failure can recover" do
    stub_request(:get, /\/paper\/ARXIV:/).to_return(status: 502).then.to_return(body: @payload.to_json)
    assert_equal "paper-1", @client.paper("1706.03762")["paper_id"]
    assert_equal [ 1, 60, 1 ], @waits
  end

  test "timeouts are bounded and do not expose upstream errors" do
    request = stub_request(:get, /\/paper\/ARXIV:/).to_timeout
    error = assert_raises(SemanticScholarClient::TemporaryError) { @client.paper("1706.03762") }
    assert_nil error.cause
    assert_requested request, times: 3
  end

  test "does not follow redirects or retry forbidden responses" do
    [ 301, 401, 403 ].each do |status|
      request = stub_paper(status: status, headers: { "Location" => "https://example.test/secret" })
      assert_raises(SemanticScholarClient::FetchError) { @client.paper("1706.03762") }
      assert_requested request, times: 1
      WebMock.reset!
    end
    assert_not_requested :get, /example\.test/
  end

  test "limits response size" do
    stub_paper(body: "x" * (SemanticScholarClient::MAX_BYTES + 1))
    assert_raises(SemanticScholarClient::FetchError) { @client.paper("1706.03762") }
  end

  test "invalid authors and optional fields fail rather than fabricate evidence" do
    @payload[:authors] = [ { authorId: "invalid", name: "Example" } ]
    stub_paper(body: @payload.to_json)
    assert_raises(SemanticScholarClient::FetchError) { @client.paper("1706.03762") }
    [ { affiliations: "unknown" }, { externalIds: [] }, { name: 123 } ].each do |fields|
      stub_request(:get, /\/author\/123/).to_return(body: { authorId: "123" }.merge(fields).to_json)
      assert_raises(SemanticScholarClient::FetchError) { @client.author("123") }
    end
  end

  test "TLS errors are not retried and contain no upstream details" do
    request = stub_request(:get, /\/paper\/ARXIV:/).to_raise(Faraday::SSLError.new("synthetic-secret"))
    error = assert_raises(SemanticScholarClient::FetchError) { @client.paper("1706.03762") }
    assert_nil error.cause
    refute_includes error.message, "synthetic-secret"
    assert_requested request, times: 1
  end

  private

  def stub_paper(status: 200, body: "", headers: {})
    stub_request(:get, /\/paper\/ARXIV:/).to_return(status: status, body: body, headers: headers)
  end
end
