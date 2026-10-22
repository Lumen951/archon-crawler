class PaperImporter
  class UnsupportedUrl < StandardError; end
  class FetchError < StandardError; end
  class TemporaryError < FetchError
    attr_reader :retry_after

    def initialize(message, retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end

  Result = Data.define(:provider, :external_id, :canonical_url, :title, :abstract, :published_at, :updated_at_source, :authors, :raw_metadata)

  def self.import!(url)
    new(url).import!
  end

  def initialize(url)
    @url = url.to_s.strip
  end

  def import!
    parsed = parse_url
    # The database lock coordinates all workers, including first imports of an ID.
    PaperSource.transaction do
      PaperSource.connection.execute("SELECT pg_advisory_xact_lock(72419001)")
      sleep 3 if parsed[:provider] == "arxiv"
      persist(fetch(parsed))
    end
  rescue Faraday::TimeoutError
    raise TemporaryError, "来源请求超时"
  rescue Faraday::ConnectionFailed => e
    raise TemporaryError, e.cause.is_a?(Timeout::Error) ? "来源请求超时" : "无法连接来源服务"
  rescue Faraday::SSLError
    raise FetchError, "来源 HTTPS 证书验证失败"
  rescue Faraday::Error => e
    Rails.logger.warn("Paper metadata request failed: #{e.class}")
    raise FetchError, "来源网络请求失败"
  rescue Nokogiri::XML::SyntaxError
    raise FetchError, "来源返回的 XML 格式无效"
  end

  def parse_url
    uri = URI.parse(@url)
    raise UnsupportedUrl, "请输入 http(s) 论文链接" unless uri.is_a?(URI::HTTP)
    raise UnsupportedUrl, "论文链接不能包含登录信息或自定义端口" if uri.userinfo || uri.port != uri.default_port

    host = uri.host.to_s.downcase
    if host == "arxiv.org" || host == "export.arxiv.org"
      path = uri.path.sub(/\.pdf\z/i, "")
      id = path.match(%r{\A/(?:abs|pdf|html)/(?<id>\d{4}\.\d{4,5}(?:v[1-9]\d*)?|[a-z-]+(?:\.[A-Z]{2})?/\d{7}(?:v[1-9]\d*)?)\z})&.[](:id)
      raise UnsupportedUrl, "无法从 arXiv 链接识别论文编号" unless id

      { provider: "arxiv", external_id: id.sub(/v\d+\z/, ""), version: id[/v(\d+)\z/, 1]&.to_i }
    elsif host == "openreview.net"
      id = URI.decode_www_form(uri.query.to_s).to_h["id"]
      unless %w[/forum /pdf].include?(uri.path) && id.to_s.match?(/\A[\w-]{1,128}\z/)
        raise UnsupportedUrl, "请输入 OpenReview forum 或 pdf 论文链接"
      end

      { provider: "openreview", external_id: id }
    else
      raise UnsupportedUrl, "仅支持 arXiv 和 OpenReview 链接"
    end
  rescue URI::InvalidURIError, ArgumentError
    raise UnsupportedUrl, "论文链接格式无效"
  end

  private

  def persist(result)
    raise FetchError, "来源没有提供论文标题" if result.title.blank?

    source = PaperSource.find_or_initialize_by(provider: result.provider, external_id: result.external_id)
    if source.persisted? && source.arxiv? &&
        source.arxiv_version.to_i > result.raw_metadata["version"].to_i
      return source.paper
    end
    source.paper ||= Paper.new
    source.paper.assign_attributes(
        title: result.title,
        abstract: result.abstract,
        published_at: result.published_at,
        updated_at_source: result.updated_at_source
    )
    source.assign_attributes(canonical_url: result.canonical_url, raw_metadata: result.raw_metadata, last_seen_at: Time.current)
    source.paper.save!
    source.save!

    result.authors.each_with_index do |author, position|
      next if author[:name].blank?

      authorship = source.paper.authorships.find_or_initialize_by(position: position)
      identity = if author[:external_id].present?
                   PaperAuthor.find_or_create_by!(provider: result.provider, external_id: author[:external_id]) do |record|
                     record.display_name = author[:name]
                   end
      else
                   # A name is a signature, not evidence of a shared identity.
                   existing = authorship.paper_author
                   if existing&.external_id.nil? && existing&.display_name == author[:name]
                     existing
                   else
                     PaperAuthor.create!(provider: result.provider, display_name: author[:name])
                   end
      end
      identity.update!(display_name: author[:name]) if identity.display_name != author[:name]
      authorship.update!(paper_author: identity, display_name: author[:name])
    end
    positions = result.authors.each_index.reject { |index| result.authors[index][:name].blank? }
    source.paper.authorships.where.not(position: positions).destroy_all

    source.paper
  end

  def fetch(parsed)
    parsed[:provider] == "arxiv" ? fetch_arxiv(parsed[:external_id], version: parsed[:version]) : fetch_openreview(parsed[:external_id])
  end

  def connection
    @connection ||= Faraday.new do |faraday|
      faraday.options.timeout = 10
      faraday.options.open_timeout = 5
    end
  end

  def fetch_arxiv(external_id, version: nil)
    query_id = version ? "#{external_id}v#{version}" : external_id
    response = get_metadata("https://export.arxiv.org/api/query", id_list: query_id, max_results: 1)
    raise FetchError, "arXiv 返回 HTTP #{response.status}" unless response.success?

    document = Nokogiri::XML(response.body) { |config| config.strict.nonet }
    entry = document.at_xpath("//*[local-name()='entry']")
    raise FetchError, "arXiv 未找到该论文" unless entry
    parse_arxiv_entry(entry, expected_id: external_id, expected_version: version, raw_xml: response.body)
  end

  def parse_arxiv_entry(entry, expected_id: nil, expected_version: nil, raw_xml:)
    returned_id = entry.at_xpath("./*[local-name()='id']")&.text.to_s
    identifier = returned_id.match(%r{\Ahttps?://arxiv\.org/abs/(?<id>\d{4}\.\d{4,5}|[a-z-]+(?:\.[A-Z]{2})?/\d{7})(?:v(?<version>[1-9]\d*))?\z})
    unless identifier && (!expected_id || identifier[:id] == expected_id)
      raise FetchError, "arXiv 返回的论文编号不匹配或查询失败"
    end
    external_id = identifier[:id]
    returned_version = identifier[:version]&.to_i
    raise FetchError, "arXiv 返回的论文版本不匹配" if expected_version && expected_version != returned_version

    authors = entry.xpath("./*[local-name()='author']").map do |author|
      { name: author.at_xpath("./*[local-name()='name']")&.text.to_s.strip, external_id: nil }
    end
    Result.new(
      "arxiv", external_id, "https://arxiv.org/abs/#{external_id}",
      entry.at_xpath("./*[local-name()='title']")&.text.to_s.squish,
      entry.at_xpath("./*[local-name()='summary']")&.text.to_s.squish,
      parse_time(entry.at_xpath("./*[local-name()='published']")&.text),
      parse_time(entry.at_xpath("./*[local-name()='updated']")&.text), authors,
      { "xml" => raw_xml, "version" => returned_version }
    )
  end

  def fetch_openreview(external_id)
    response = get_metadata("https://api2.openreview.net/notes", id: external_id, limit: 1)
    raise FetchError, "OpenReview 返回 HTTP #{response.status}" unless response.success?

    payload = JSON.parse(response.body)
    raise FetchError, "OpenReview 返回内容格式无效" unless payload.is_a?(Hash)
    note = Array(payload["notes"]).first || payload["note"]
    raise FetchError, "OpenReview 未找到该论文" unless note.is_a?(Hash)
    unless note["id"] == external_id && note["forum"] == external_id && note["replyto"].blank?
      raise FetchError, "该 OpenReview 链接不是可导入的主论文"
    end

    content = note.fetch("content", {})
    raise FetchError, "OpenReview 返回内容格式无效" unless content.is_a?(Hash)
    value = ->(key) { content[key].is_a?(Hash) ? content[key]["value"] : content[key] }
    author_ids = Array(value.call("authorids"))
    authors = Array(value.call("authors")).each_with_index.filter_map do |name, index|
      name = name["fullname"] if name.is_a?(Hash)
      next if name.to_s.strip.blank?

      identity = author_ids[index]
      id = (identity.is_a?(Hash) ? identity["username"] : identity).to_s
      { name: name.to_s.strip, external_id: id.match?(/\A~[\p{L}\p{N}_.-]+\z/) ? id : nil }
    end
    Result.new(
      "openreview", external_id, "https://openreview.net/forum?id=#{CGI.escape(external_id)}",
      value.call("title").to_s, value.call("abstract").to_s,
      parse_milliseconds(note["pdate"]) || parse_time(value.call("publication_date")),
      parse_milliseconds(note["tmdate"] || note["mdate"]), authors, payload
    )
  rescue JSON::ParserError
    raise FetchError, "OpenReview 返回内容不是有效 JSON"
  end

  def get_metadata(url, params)
    body = +""
    response = connection.get(url, params) do |request|
      request.options.on_data = lambda do |chunk, _size, _env|
        raise FetchError, "来源元数据超过 2 MB 限制" if body.bytesize + chunk.bytesize > 2.megabytes

        body << chunk
      end
    end
    response.env.body = body
    if [ 429, 502, 503, 504 ].include?(response.status)
      reason = response.status == 429 ? "来源限流" : "来源暂时不可用"
      raise TemporaryError.new("#{reason}（HTTP #{response.status}）", retry_after: retry_after(response.headers["retry-after"]))
    end
    response
  end

  def retry_after(value)
    return if value.blank?
    return value.to_i if value.match?(/\A\d+\z/)

    [ Time.httpdate(value) - Time.current, 0 ].max.ceil
  rescue ArgumentError
    nil
  end

  def parse_time(value)
    return if value.blank?
    return parse_milliseconds(value) if value.is_a?(Numeric)

    Time.iso8601(value.to_s).in_time_zone
  rescue ArgumentError
    nil
  end

  def parse_milliseconds(value)
    Time.at(value / 1000.0).in_time_zone if value.is_a?(Numeric) && value.positive?
  rescue RangeError, ArgumentError
    nil
  end
end
