require "test_helper"

# Fetcher 的字节安全 query 处理、字符集恢复与网络错误归类。
# 全部离线：用自带的 echo adapter 记录 Faraday 真正请求的 URL，不发真实请求。
class WebsiteCrawlerFetcherTest < ActiveSupport::TestCase
  # GBK 编码的「杨超」，即新浪 / 搜索引擎结果里常见的 `Name=%D1%EE%B3%AC`。
  GBK_NAME_BYTES = "%D1%EE%B3%AC"
  # GBK 编码的「你好」原始字节
  GBK_HELLO = "\xC4\xE3\xBA\xC3".b.freeze

  # 记录请求、按 path 返回预设响应的 adapter（不联网）
  class EchoAdapter < Faraday::Adapter
    class << self
      attr_accessor :requests, :responses
    end

    def self.reset!
      self.requests = []
      self.responses = {}
    end

    reset!

    def call(env)
      super
      self.class.requests << env[:url].to_s
      status, body, headers = self.class.responses.fetch(env[:url].path, [ 200, HTML_BODY, HTML_HEADERS ])
      save_response(env, status, body, headers)
      @app.call(env)
    end
  end

  HTML_BODY = "<html><head><title>标题</title></head><body>正文</body></html>".freeze
  HTML_HEADERS = { "content-type" => "text/html; charset=utf-8" }.freeze

  def setup
    EchoAdapter.reset!
  end

  def build_fetcher
    fetcher = WebsiteCrawler::Fetcher.new(timeout: 5)
    # 用 Fetcher 自己建的生产连接（保留 params_encoder / retry 等全部配置），
    # 只把传输层换成 echo adapter —— 若哪天 connection 里漏了 params_encoder，
    # 这里的测试会直接失败，而不是被测试自己的配置掩盖。
    fetcher.send(:connection).adapter(EchoAdapter)
    fetcher
  end

  # --- ByteSafeParamsEncoder ---------------------------------------------

  test "escape/unescape 逐字节无损往返" do
    encoder = WebsiteCrawler::Fetcher::ByteSafeParamsEncoder

    [ GBK_NAME_BYTES, "a%20b", "a%26b", "%E4%B8%AD%E6%96%87", "a+b", "plain" ].each do |value|
      assert_equal value, encoder.unescape(encoder.escape(value)), "escape/unescape 往返失败: #{value}"
    end
  end

  test "escape 会转义保留字符、保留非保留字符" do
    encoder = WebsiteCrawler::Fetcher::ByteSafeParamsEncoder

    assert_equal "a%20b", encoder.escape("a b")
    assert_equal "a%26b%3Dc", encoder.escape("a&b=c")
    assert_equal "AZaz09-._~", encoder.escape("AZaz09-._~")
    # 数组参数保持原样，不变成 %5B%5D（default_params_encoder 同样不转义）
    assert_equal "ids[]=1", encoder.encode_pairs([ [ "ids[]", "1" ] ])
  end

  test "decode_pairs 保留重复键与无值参数" do
    encoder = WebsiteCrawler::Fetcher::ByteSafeParamsEncoder

    assert_equal [ [ "ids[]", "1" ], [ "ids[]", "2" ] ], encoder.decode_pairs("ids[]=1&ids[]=2")
    assert_equal [ [ "flag", nil ] ], encoder.decode_pairs("flag")
    # 表单编码里的 + 代表空格
    assert_equal [ [ "a", "b c" ] ], encoder.decode_pairs("a=b+c")
  end

  test "Faraday 请求含 GBK query 的 URL 不抛 invalid byte sequence" do
    fetcher = build_fetcher
    url = "https://vip.stock.finance.sina.com.cn/quotes_service/api/json_v2.php/Market_Center.getHQNodeData?page=1&Name=#{GBK_NAME_BYTES}&sort=symbol"

    result = fetcher.fetch(url)

    assert result.success?, "应抓取成功，实际 #{result.kind}: #{result.error}"
    assert_equal url, EchoAdapter.requests.first, "请求 URL 里的 GBK 字节被改写了"
  end

  test "Faraday 请求保留重复键与显式 params" do
    fetcher = build_fetcher
    url = "https://example.com/list?ids[]=1&ids[]=2&page=3"

    assert fetcher.fetch(url).success?
    assert_equal url, EchoAdapter.requests.first
  end

  test "encode 在显式传入 params 时把默认 encoder 的结果追加在原 query 之后" do
    encoder = WebsiteCrawler::Fetcher::ByteSafeParamsEncoder
    params = encoder.decode("a=1")
    params.update("b" => "2")

    assert_equal "a=1&b=2", encoder.encode(params)
  end

  # --- normalize ----------------------------------------------------------

  test "normalize 保留非 UTF-8 字节的 query" do
    target = WebsiteCrawler::Fetcher.normalize(
      "https://example.com/",
      "/a?Name=#{GBK_NAME_BYTES}&x=1"
    )

    assert_equal "https://example.com/a?Name=#{GBK_NAME_BYTES}&x=1", target
  end

  test "normalize 去掉 fragment 与跟踪参数，保留其他参数与重复键" do
    target = WebsiteCrawler::Fetcher.normalize(
      "https://example.com/",
      "/a?utm_source=x&ids[]=1&ids[]=2&id=922#section"
    )

    assert_equal "https://example.com/a?ids[]=1&ids[]=2&id=922", target
  end

  test "normalize 去掉全部参数后不带问号" do
    target = WebsiteCrawler::Fetcher.normalize("https://example.com/", "/a?utm_source=x&fbclid=y")

    assert_equal "https://example.com/a", target
  end

  test "normalize 拒绝不可用链接" do
    assert_nil WebsiteCrawler::Fetcher.normalize("https://example.com/", "mailto:a@b.com")
    assert_nil WebsiteCrawler::Fetcher.normalize("https://example.com/", "#anchor")
    assert_nil WebsiteCrawler::Fetcher.normalize("https://example.com/", "javascript:void(0)")
    assert_nil WebsiteCrawler::Fetcher.normalize("https://example.com/", "ftp://example.com/a")
  end

  # --- decode_body --------------------------------------------------------

  test "decode_body 按 Content-Type 的 charset 解码 GBK" do
    response = fake_response("text/html; charset=gbk")

    decoded = fetch_decode_body(response, GBK_HELLO)

    assert_equal "你好", decoded
    assert_equal Encoding::UTF_8, decoded.encoding
  end

  test "decode_body 在 Content-Type 没有 charset 时嗅探 meta 声明" do
    response = fake_response("text/html")
    body = "<html><head><meta charset=gbk></head><body>#{GBK_HELLO}</body></html>".b

    decoded = fetch_decode_body(response, body)

    assert_includes decoded, "你好"
  end

  test "decode_body 对未知字符集名不抛异常" do
    response = fake_response("text/html; charset=x-gbk")
    body = "<html><body>#{GBK_HELLO}</body></html>".b

    decoded = fetch_decode_body(response, body)

    assert_equal Encoding::UTF_8, decoded.encoding
    assert decoded.valid_encoding?
  end

  test "decode_body 把非法 UTF-8 字节替换掉而不是抛异常" do
    response = fake_response("text/html")
    body = "<html><body>abc#{GBK_HELLO}def</body></html>".b

    decoded = fetch_decode_body(response, body)

    assert_includes decoded, "abc"
    assert_includes decoded, "def"
    assert decoded.valid_encoding?
  end

  # --- TLS 放宽 -----------------------------------------------------------

  # 国内政府 / 高校站点证书链不全或已过期是常态，严格校验会让整页抓不下来。
  # 这条连接只用于 GET 公开网页，不携带凭据，所以统一不校验。
  test "抓取连接关闭 TLS 证书校验" do
    assert_equal false, WebsiteCrawler::Fetcher.new(timeout: 5).send(:connection).ssl.verify
    assert_equal false, WebsiteCrawler::ScrapingAntFetcher.new.send(:connection).ssl.verify
  end

  # --- fetch 的失败归类 ---------------------------------------------------

  test "fetch 把 SSL 错误归类为 network_error 而不是抛出去" do
    fetcher = WebsiteCrawler::Fetcher.new
    failing = Object.new
    def failing.get(*)
      raise Faraday::SSLError, "SSL_connect returned=1 errno=0 peeraddr=1.2.3.4:443 state=error: bad ecpoint"
    end
    fetcher.instance_variable_set(:@connection, failing)

    result = fetcher.fetch("https://example.com/")

    assert_equal :network_error, result.kind
    assert_includes result.error, "bad ecpoint"
    assert_not result.success?
  end

  test "fetch 把超时归类为 timeout" do
    fetcher = WebsiteCrawler::Fetcher.new
    failing = Object.new
    def failing.get(*)
      raise Faraday::TimeoutError, "Net::ReadTimeout"
    end
    fetcher.instance_variable_set(:@connection, failing)

    assert_equal :timeout, fetcher.fetch("https://example.com/").kind
  end

  test "fetch 跟随重定向且目标 URL 的 GBK query 不被改写" do
    EchoAdapter.responses["/a"] = [ 302, "", { "location" => "https://example.com/b?Name=#{GBK_NAME_BYTES}" } ]
    fetcher = build_fetcher

    result = fetcher.fetch("https://example.com/a")

    assert result.success?, "重定向后应成功，实际 #{result.kind}: #{result.error}"
    assert_equal [ "https://example.com/a", "https://example.com/b?Name=#{GBK_NAME_BYTES}" ], EchoAdapter.requests
  end

  test "fetch 拒绝 PDF 等非 HTML 资源" do
    EchoAdapter.responses["/doc.pdf"] = [ 200, "%PDF-1.7", { "content-type" => "application/pdf" } ]

    result = build_fetcher.fetch("https://example.com/doc.pdf")

    assert_equal :unsupported, result.kind
    assert_nil result.html
  end

  test "fetch 拒绝非 http(s) 协议" do
    assert_equal :unsupported, build_fetcher.fetch("ftp://example.com/a").kind
  end

  test "fetch 把 403 归类为 blocked，且不重试" do
    EchoAdapter.responses["/blocked"] = [ 403, "no", HTML_HEADERS ]

    assert_equal :blocked, build_fetcher.fetch("https://example.com/blocked").kind
    assert_equal 1, EchoAdapter.requests.length, "403 不应被重试"
  end

  test "fetch 对 429 会按 retry_statuses 重试后再归类为 rate_limited" do
    EchoAdapter.responses["/limited"] = [ 429, "slow down", HTML_HEADERS ]

    assert_equal :rate_limited, build_fetcher.fetch("https://example.com/limited").kind
    # max: 2 → 首次 + 2 次重试；faraday-retry 默认不重试状态码，这条断言守住这个配置
    assert_equal 3, EchoAdapter.requests.length
  end

  private

  def fake_response(content_type)
    Struct.new(:headers).new({ "content-type" => content_type })
  end

  # decode_body 是私有方法：只测字符集恢复本身，不经过网络
  def fetch_decode_body(response, body)
    WebsiteCrawler::Fetcher.new.send(:decode_body, response, body)
  end
end
