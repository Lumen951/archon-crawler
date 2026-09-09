require "test_helper"
require "website_crawler"

class ExtractorTest < ActiveSupport::TestCase
  def extractor
    WebsiteCrawler::Extractor.new
  end

  test "extract_article keeps article markup and drops site chrome" do
    html = <<~HTML
      <html><head><title>Deep dive</title></head>
      <body>
        <nav><a href="/login">Login</a></nav>
        <header>Site header</header>
        <article>
          <h1>Full Post</h1>
          <p>Some <strong>real</strong> paragraph text that is long enough to pass the threshold check.</p>
          <script>bad()</script>
        </article>
        <footer>footer</footer>
      </body></html>
    HTML

    result = extractor.extract_article(html, "https://example.com/post")

    assert result.html.present?
    refute_includes result.html, "Site header"
    refute_includes result.html, "<script"
    refute_includes result.html, "footer"
    assert_includes result.html, "<strong>real</strong>"
    assert result.markdown.present?
    assert_operator result.text_length, :>=, 80
  end

  test "extract_article prefers article over main and body" do
    html = <<~HTML
      <html><body>
        <main><p>#{'Main content text long enough to pass the threshold. ' * 3}</p></main>
        <article><p>#{'Article body text long enough to pass the threshold. ' * 3}</p></article>
      </body></html>
    HTML

    result = extractor.extract_article(html)

    assert_includes result.html, "Article body text"
    refute_includes result.html, "Main content text"
  end

  test "extract_article absolutizes relative links and images" do
    html = <<~HTML
      <html><body><article>
        <p><a href="/about">About</a></p>
        <img src="/img/a.png">
        <p>#{'Enough body text to pass the minimum length threshold used below.' * 3}</p>
      </article></body></html>
    HTML

    result = extractor.extract_article(html, "https://example.com/post/1")

    assert_includes result.html, 'href="https://example.com/about"'
    assert_includes result.html, 'src="https://example.com/img/a.png"'
  end

  test "extract_article returns nil html when the page is too short" do
    html = "<html><body><article><p>Too short</p></article></body></html>"

    result = extractor.extract_article(html)

    assert_nil result.html
    assert_nil result.markdown
    assert_operator result.text_length, :<, 80
  end
end
