require "digest"
require "fileutils"

class PaperFullTextDownloader
  class Unavailable < PaperImporter::FetchError; end

  HTML_LIMIT = 5.megabytes
  IMAGE_LIMIT = 5.megabytes
  TOTAL_LIMIT = 40.megabytes
  IMAGE_COUNT_LIMIT = 100
  TAGS = %w[article section header footer nav div span p h1 h2 h3 h4 h5 h6
    a img figure figcaption table caption thead tbody tfoot tr th td
    ul ol li dl dt dd blockquote pre code em strong b i u s small sub sup
    br hr abbr cite q time math semantics annotation mrow mi mn mo mtext
    mspace ms mfrac msqrt mroot mstyle merror mpadded mphantom mfenced menclose
    msub msup msubsup munder mover munderover mmultiscripts mprescripts none
    mtable mtr mtd mlabeledtr maligngroup].freeze
  ATTRIBUTES = %w[id class title alt colspan rowspan scope start value
    display mathvariant mathsize mathcolor displaystyle scriptlevel
    stretchy symmetric fence separator accent accentunder lspace rspace
    columnalign rowalign columnspacing rowspacing columnspan
    linethickness notation encoding].freeze
  DROP = %w[script style link iframe object embed form input button textarea
    select template svg annotation-xml audio video source base meta].freeze

  def initialize(record)
    @record = record
    @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 600
  end

  def download!
    source = @record.paper_source
    unless source.arxiv? && source.external_id.match?(%r{\A(?:\d{4}\.\d{4,5}|[a-z-]+(?:\.[A-Z]{2})?/\d{7})\z})
      raise PaperImporter::FetchError, "不支持此全文来源"
    end

    response = request(@record.source_url, HTML_LIMIT)
    raise Unavailable if [ 404, 410 ].include?(response.status)
    check_response!(response)
    unless response.headers["content-type"].to_s.downcase.start_with?("text/html")
      raise PaperImporter::FetchError, "来源返回的内容不是 HTML"
    end

    document = Nokogiri::HTML5(response.body)
    article = document.at_css("article.ltx_document")
    raise PaperImporter::FetchError, "来源页面未包含论文正文" unless article && article.text.strip.present?

    FileUtils.mkdir_p(@record.directory)
    clean!(article)
    images = article.css("img")
    raise PaperImporter::FetchError, "论文图片数量超过本次下载上限" if images.length > IMAGE_COUNT_LIMIT

    images.each { |image| localize_image!(image) }
    temporary = @record.directory.join("article.part")
    File.binwrite(temporary, article.to_html)
    File.rename(temporary, @record.html_path)
    @record.update!(status: :ready, error_message: nil, downloaded_at: Time.current, retry_at: nil)
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed
    raise PaperImporter::TemporaryError, "全文来源连接失败或超时"
  rescue Faraday::SSLError
    raise PaperImporter::FetchError, "全文来源 HTTPS 连接或证书验证失败"
  rescue Faraday::Error
    raise PaperImporter::FetchError, "全文来源网络请求失败"
  end

  private

  def clean!(article)
    article.css(DROP.join(",")).remove
    article.xpath(".//comment()").remove
    article.traverse do |node|
      next unless node.element?

      unless TAGS.include?(node.name)
        node.replace(node.children)
        next
      end
      node.attribute_nodes.each do |attribute|
        allowed = ATTRIBUTES.include?(attribute.name) ||
          (node.name == "img" && attribute.name == "src") ||
          (node.name == "a" && attribute.name == "href")
        attribute.remove unless allowed && attribute.namespace.nil?
      end
      next unless node.name == "a" && node["href"]

      href = node["href"]
      if href.start_with?("#") && !href.match?(/[\x00-\x20]/)
        next
      elsif href.match?(%r{\Ahttps?://}i)
        node["rel"] = "noopener noreferrer"
        node["target"] = "_blank"
      else
        node.remove_attribute("href")
      end
    end
  end

  def localize_image!(image)
    url = image_url(image["src"])
    key = Digest::SHA256.hexdigest(url)
    cached = @record.resources[key]
    if cached && File.file?(@record.directory.join(key))
      image["src"] = resource_path(key)
      return
    end

    response = request(url, IMAGE_LIMIT)
    check_response!(response)
    type = image_type(response.body)
    raise PaperImporter::FetchError, "论文包含暂不支持的图片格式，未标记为完整下载" unless type
    total = @record.resources.except(key).values.sum { |resource| resource["bytes"].to_i } + response.body.bytesize
    raise PaperImporter::FetchError, "论文资源总大小超过 40 MB 限制" if total > TOTAL_LIMIT

    File.binwrite(@record.directory.join("#{key}.part"), response.body)
    File.rename(@record.directory.join("#{key}.part"), @record.directory.join(key))
    @record.update!(resources: @record.resources.merge(
      key => { "type" => type, "bytes" => response.body.bytesize, "source_url" => url }
    ))
    image["src"] = resource_path(key)
  end

  def resource_path(key)
    Rails.application.routes.url_helpers.full_text_asset_paper_path(
      @record.paper_source.paper_id, full_text_id: @record.id, resource: key
    )
  end

  def image_url(value)
    uri = URI.join(@record.source_url, value.to_s)
    prefix = "/html/#{@record.paper_source.external_id}v#{@record.version}/"
    unless value.present? && uri.scheme == "https" && uri.host == "arxiv.org" &&
        uri.port == 443 && !uri.userinfo && !uri.query && !uri.fragment &&
        uri.path.start_with?(prefix) && !uri.path.match?(/[%\\]/)
      raise PaperImporter::FetchError, "论文图片地址不在允许的来源范围内"
    end
    uri.to_s
  rescue URI::InvalidURIError
    raise PaperImporter::FetchError, "论文图片地址无效"
  end

  def image_type(body)
    bytes = body.b
    return "image/png" if bytes.start_with?("\x89PNG\r\n\x1a\n".b)
    return "image/jpeg" if bytes.start_with?("\xff\xd8\xff".b)
    return "image/gif" if bytes.start_with?("GIF87a", "GIF89a")
    "image/webp" if bytes.start_with?("RIFF") && bytes[8, 4] == "WEBP"
  end

  def check_response!(response)
    if [ 429, 502, 503, 504 ].include?(response.status)
      header = response.headers["retry-after"].to_s
      retry_after = if header.match?(/\A\d+\z/)
        header.to_i
      else
        begin
          [ (Time.httpdate(header) - Time.current).ceil, 0 ].max
        rescue ArgumentError
          nil
        end
      end
      raise PaperImporter::TemporaryError.new("全文来源暂时不可用（HTTP #{response.status}）", retry_after: retry_after)
    end
    raise PaperImporter::FetchError, "全文来源返回 HTTP #{response.status}" unless response.success?
  end

  def request(url, limit)
    # Share the metadata import lock; images must not create a second arXiv connection.
    PaperSource.connection_pool.with_connection do |connection|
      connection.execute("SELECT pg_advisory_lock(72419001)")
      begin
        raise PaperImporter::FetchError, "全文下载超过十分钟，请稍后重试" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline

        sleep 3
        body = +"".b
        response = Faraday.new do |client|
          client.options.timeout = 20
          client.options.open_timeout = 5
          client.headers["User-Agent"] = "Archon-PaperReader/1.0"
        end.get(url) do |req|
          req.options.on_data = lambda do |chunk, _size, _env|
            raise PaperImporter::FetchError, "全文或图片超过下载大小限制" if body.bytesize + chunk.bytesize > limit

            body << chunk.b
          end
        end
        response.env.body = body
        response
      ensure
        connection.execute("SELECT pg_advisory_unlock(72419001)")
      end
    end
  end
end
