require "nokogiri"
require "async"
require "async/semaphore"

# 网页正文抓取：复用生产的 WebsiteCrawler::Fetcher（重定向 / 重试 / 字符集恢复 / PDF 拒绝），
# 正文抽取走 WebsiteCrawler::Extractor。
class EventResearch::PageFetcher
  # 只有这些失败是「下次可能就好了」的，不写缓存、重跑会重试。
  # 其余（非 HTML 资源、正文为空等）都是确定性结果，缓存下来免得断点续跑时反复抓。
  TRANSIENT_KINDS = %w[timeout blocked rate_limited server_error network_error].freeze

  # 反爬验证页的指纹（HTTP 200 + 几乎没有正文）。百度百科对非浏览器客户端一律返回
  # 「安全校验中…」的 JS 空壳，这类页面不是「这个 URL 没有正文」，换个时间/出口再跑
  # 往往就有了，缓存一周会把一次偶发拦截钉死。
  CHALLENGE_MARKERS = [ "安全校验中", "请开启JavaScript", "正在验证您", "Just a moment",
                        "cf-browser-verification", "enable JavaScript and cookies" ].freeze

  def initialize(cache:, reporter:, timeout: 15, concurrency: EventResearch::FETCH_CONCURRENCY)
    @cache = cache
    @reporter = reporter
    @concurrency = concurrency
    @fetcher = WebsiteCrawler::Fetcher.new(timeout: timeout)
    @extractor = WebsiteCrawler::Extractor.new
  end

  # 返回带字符串键的 Hash：成功为 { "url", "title", "text", "kind" => "success" }，
  # 失败为 { "url", "kind", "error" }（无 "text"，由调用方计入失败清单）。
  def fetch(url)
    @cache.wrap("document", "#{EventResearch::DOCUMENT_VERSION}:#{url}", ttl: EventResearch::CACHE_TTLS["document"], label: url,
                cache_if: ->(page) { !TRANSIENT_KINDS.include?(page["kind"]) }) do
      perform(url)
    end
  end

  # 并发抓取一批 URL（Async::Semaphore 限流），返回数组与 urls 一一对应、顺序一致 ——
  # 顺序稳定，组装出的文档列表与 LLM prompt 缓存键才不会随抓取快慢抖动。
  # 单个 URL 失败/抛异常只影响它自己那一格（Async 里异常会冒泡到 barrier 取消整批），
  # 因此每个任务内部自行 rescue，失败按 network_error 记一笔，由调用方计入失败清单。
  def fetch_many(urls, concurrency: @concurrency)
    return [] if urls.empty?

    pages = Array.new(urls.length)
    done = 0
    total = urls.length

    # Sync 而不是 Async：在已有 reactor 里也能正确阻塞到全部完成，
    # 顶层调用时会自行建 reactor 并跑完再返回。
    Sync do
      semaphore = Async::Semaphore.new(concurrency)
      barrier = Async::Barrier.new

      urls.each_with_index do |url, index|
        barrier.async do
          semaphore.acquire do
            pages[index] = fetch_one(url)
            done += 1
            @reporter.info("Fetch [#{done}/#{total}] #{url}")
          end
        end
      end

      barrier.wait
    end

    pages
  end

  private

  def fetch_one(url)
    fetch(url)
  rescue StandardError => e
    @reporter.error("抓取异常: #{url}（#{e.class}: #{e.message}）", exception: e)
    { "url" => url, "kind" => "network_error", "error" => "#{e.class}: #{e.message}".scrub }
  end

  def perform(url)
    result = @fetcher.fetch(url)

    unless result.success?
      message = "抓取失败 [#{result.kind}] #{url}"
      message += " - #{result.error}" if result.error
      @reporter.warn(message)
      return { "url" => url, "kind" => result.kind.to_s, "error" => result.error.to_s.scrub }
    end

    title, text = extract(result.html, url)

    if text.length < EventResearch::MIN_DOC_CHARS && challenge_page?(result.html)
      # 归到 blocked：它在 TRANSIENT_KINDS 里，不写缓存，重跑会重试
      @reporter.warn("疑似反爬验证页（不缓存，重跑会重试）: #{url}")
      return { "url" => url, "kind" => "blocked", "error" => "反爬验证页" }
    end

    if text.empty?
      @reporter.warn("页面没有可读正文: #{url}")
      return { "url" => url, "kind" => "empty", "error" => "正文为空" }
    end

    @reporter.debug("  取到正文 #{text.length} 字符: #{url}")
    { "url" => url, "title" => title, "text" => text, "kind" => "success" }
  end

  def extract(html, url)
    extracted = @extractor.extract(html, url)
    title = extracted.title.to_s.scrub.strip
    text = normalize(extracted.content)

    # Extractor 会取 article/main/body，但空壳页面里往往有个空的 <article>，
    # 正文其实在别处 —— 这时退回整页文本。注意要先去掉 script/style，
    # 否则兜底捞上来的全是 JS 源码。
    text = normalize(body_text(html)) if text.empty?

    [ title, text ]
  end

  # 只在正文明显不足时才看指纹，正常页面不会被这几个词误伤
  def challenge_page?(html)
    sample = html.to_s
    CHALLENGE_MARKERS.any? { |marker| sample.include?(marker) }
  end

  def body_text(html)
    doc = Nokogiri::HTML(html.to_s)
    WebsiteCrawler::Extractor::BASE_REMOVE.each { |tag| doc.css(tag).remove }

    doc.at("body")&.text
  end

  def normalize(text)
    text.to_s.scrub
        .gsub(/ /, " ")
        .gsub(/[ \t]+/, " ")
        .gsub(/\n{2,}/, "\n")
        .strip
        .slice(0, EventResearch::MAX_DOC_CHARS)
        .to_s
  end
end
