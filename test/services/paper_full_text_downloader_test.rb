require "test_helper"
require "webmock/minitest"
require "tmpdir"

class PaperFullTextDownloaderTest < ActiveSupport::TestCase
  PNG = Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=").freeze

  class Downloader < PaperFullTextDownloader
    def sleep(_seconds); end
  end

  setup do
    paper = Paper.create!(title: "Synthetic paper")
    @source = paper.sources.create!(provider: :arxiv, external_id: "2401.00001",
      canonical_url: "https://arxiv.org/abs/2401.00001", raw_metadata: { version: 1 })
    @record = @source.prepare_full_text!
    @html = File.read(Rails.root.join("e2e/fixtures/paper_full_text.html"))
    @image_url = "https://arxiv.org/html/2401.00001v1/x1.png"
  end

  test "saves sanitized full text math and deduplicated local images" do
    html = @html.sub("</section>", '<script>alert(1)</script><iframe src="/"></iframe><img src="2401.00001v1/x1.png" onerror="alert(1)"><a href="javascript:alert(1)">bad</a></section>')
    stub_html(html)
    stub_request(:get, @image_url).to_return(body: PNG, headers: { "Content-Type" => "image/png" })
    with_storage do
      Downloader.new(@record).download!
      assert @record.reload.status_ready?
      saved = File.read(@record.html_path)
      assert_includes saved, "<math"
      assert_includes saved, 'href="#S1"'
      assert_includes saved, "full_text_asset"
      refute_match(/<script|<iframe|onerror|javascript:|src="https:/, saved)
      assert_equal 1, @record.resources.size
      assert_requested :get, @image_url, times: 1
      assert_equal PNG, File.binread(@record.directory.join(@record.resources.keys.first))
      assert @record.locally_available?
      File.delete(@record.directory.join(@record.resources.keys.first))
      refute @record.locally_available?
      assert @record.retryable?
    end
  end

  test "rejects external images and redirects without contacting their target" do
    with_storage do
      %w[https://example.test/private http://127.0.0.1/secret //localhost/secret
        ../secret /html/2401.00001v1/%2e%2e/secret].each do |url|
        stub_html(@html.sub("2401.00001v1/x1.png", url))
        assert_raises(PaperImporter::FetchError) { Downloader.new(@record).download! }
      end
      stub_html
      stub_request(:get, @image_url).to_return(status: 302, headers: { "Location" => "http://127.0.0.1/secret" })
      assert_raises(PaperImporter::FetchError) { Downloader.new(@record).download! }
      refute @record.reload.status_ready?
      assert_not_requested :get, "http://127.0.0.1/secret"
    end
  end

  test "missing HTML differs from rate limits and invalid successful responses" do
    stub_request(:get, @record.source_url).to_return(status: 404)
    assert_raises(PaperFullTextDownloader::Unavailable) { Downloader.new(@record).download! }
    stub_request(:get, @record.source_url).to_return(status: 429, headers: { "Retry-After" => "180" })
    error = assert_raises(PaperImporter::TemporaryError) { Downloader.new(@record).download! }
    assert_equal 180, error.retry_after
    stub_html("<html><body>Access denied</body></html>")
    assert_raises(PaperImporter::FetchError) { Downloader.new(@record).download! }
    stub_request(:get, @record.source_url).to_return(status: 200, body: @html, headers: { "Content-Type" => "application/json" })
    assert_raises(PaperImporter::FetchError) { Downloader.new(@record).download! }
    stub_request(:get, @record.source_url).to_raise(OpenSSL::SSL::SSLError.new("unexpected eof while reading"))
    error = assert_raises(PaperImporter::FetchError) { Downloader.new(@record).download! }
    assert_equal "全文来源 HTTPS 连接或证书验证失败", error.message
  end

  test "oversized HTML and unsupported images never become ready" do
    stub_html("x" * (PaperFullTextDownloader::HTML_LIMIT + 1))
    assert_raises(PaperImporter::FetchError) { Downloader.new(@record).download! }
    with_storage do
      stub_html
      stub_request(:get, @image_url).to_return(body: "<svg onload='alert(1)'/>", headers: { "Content-Type" => "image/png" })
      assert_raises(PaperImporter::FetchError) { Downloader.new(@record).download! }
      refute @record.reload.status_ready?
      assert_empty @record.resources
    end
  end

  test "retries reuse downloaded images after a later image fails" do
    second = "https://arxiv.org/html/2401.00001v1/x2.png"
    stub_html(@html.sub("</section>", '<img src="2401.00001v1/x2.png"></section>'))
    stub_request(:get, @image_url).to_return(body: PNG)
    stub_request(:get, second).to_timeout
    with_storage do
      assert_raises(PaperImporter::TemporaryError) { Downloader.new(@record).download! }
      assert_equal 1, @record.reload.resources.size
      refute File.exist?(@record.html_path)
      stub_request(:get, second).to_return(body: PNG)
      Downloader.new(@record).download!
      assert @record.reload.status_ready?
      assert_requested :get, @image_url, times: 1
    end
  end

  test "active attributes and foreign content are removed from MathML" do
    stub_html(@html.sub("</section>", <<~HTML))
      <math href="javascript:alert(1)" style="background:url(https://example.test)">
        <annotation-xml encoding="text/html"><script>alert(1)</script></annotation-xml>
        <mtext onclick="alert(1)">safe</mtext>
      </math><svg><foreignObject>unsafe</foreignObject></svg></section>
    HTML
    stub_request(:get, @image_url).to_return(body: PNG)
    with_storage do
      Downloader.new(@record).download!
      saved = File.read(@record.html_path)
      refute_match(/annotation-xml|script|onclick|style=|<svg|foreignObject|javascript:/, saved)
      assert_includes saved, "<mtext>safe</mtext>"
    end
  end

  test "old metadata exposes its version without a network request" do
    @source.update!(raw_metadata: { "xml" => "<feed><entry><id>http://arxiv.org/abs/2401.00001v2</id></entry></feed>" })
    assert_equal 2, @source.arxiv_version
    assert_difference "PaperFullText.count", 1 do
      assert_equal 2, @source.prepare_full_text!.version
    end
    assert_no_difference "PaperFullText.count" do
      @source.prepare_full_text!
    end
  end

  private

  def stub_html(body = @html)
    stub_request(:get, @record.source_url).to_return(body: body, headers: { "Content-Type" => "text/html; charset=utf-8" })
  end

  def with_storage(&block)
    Dir.mktmpdir("paper-full-text-test") do |directory|
      stub_class_method(PaperFullText, :storage_root, -> { Pathname.new(directory) }, &block)
    end
  end
end
