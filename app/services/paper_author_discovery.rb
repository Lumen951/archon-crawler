class PaperAuthorDiscovery < PaperImporter
  PAGE_SIZE = 50
  MAX_RESULTS = 30_000
  Page = Data.define(:results, :total)

  def initialize(run)
    super(nil)
    @run = run
  end

  def fetch_page
    names = @run.name_variants.map { |name| %(au:"#{name}") }.join(" OR ")
    query = "(#{names}) AND submittedDate:[199101010000 TO #{@run.cutoff_at.utc.strftime('%Y%m%d%H%M')}]"
    response = get_metadata("https://export.arxiv.org/api/query",
      search_query: query, start: @run.next_offset, max_results: PAGE_SIZE,
      sortBy: "submittedDate", sortOrder: "ascending")
    raise FetchError, "arXiv 作者查询返回 HTTP #{response.status}" unless response.success?

    document = Nokogiri::XML(response.body) { |config| config.strict.nonet }
    namespace = { "atom" => "http://www.w3.org/2005/Atom", "os" => "http://a9.com/-/spec/opensearch/1.1/" }
    total = integer_value(document.at_xpath("/atom:feed/os:totalResults", namespace))
    start = integer_value(document.at_xpath("/atom:feed/os:startIndex", namespace))
    raise FetchError, "arXiv 分页位置不匹配，未推进进度" unless start == @run.next_offset
    raise FetchError, "查询超过单次历史回溯容量，请收窄姓名别名后重试" if total > MAX_RESULTS
    if @run.total_count && total != @run.total_count
      raise FetchError, "来源结果数量发生变化，请重新回溯；已有候选与人工决定保留"
    end

    entries = document.xpath("/atom:feed/atom:entry", namespace)
    if entries.length > PAGE_SIZE || start + entries.length > total || (entries.empty? && start < total)
      raise FetchError, "arXiv 分页数据不完整，未推进进度"
    end
    results = entries.map { |entry| parse_arxiv_entry(entry, raw_xml: entry.to_xml) }
    raise FetchError, "arXiv 当前页存在重复论文，未推进进度" unless results.map(&:external_id).uniq.size == results.size

    Page.new(results, total)
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed
    raise TemporaryError, "作者查询连接失败或超时"
  rescue Faraday::SSLError
    raise FetchError, "作者查询 HTTPS 连接或证书验证失败"
  rescue Faraday::Error
    raise FetchError, "作者查询网络请求失败"
  rescue Nokogiri::XML::SyntaxError
    raise FetchError, "作者查询返回的 XML 无效"
  end

  def save_page!(page)
    subscription = @run.paper_subscription
    page.results.each do |result|
      paper = persist(result)
      source = paper.sources.find_by!(provider: "arxiv", external_id: result.external_id)
      match = subscription.matches.find_or_initialize_by(paper_source: source)
      if match.evidence["run_id"] == @run.id
        raise FetchError, "来源跨页返回重复论文，请重新回溯；未推进当前页"
      end
      names = result.authors.map { |author| author[:name] }
      variants = @run.name_variants.map { |name| PaperSubscription.normalize_name(name) }
      positions = names.each_index.select { |index| variants.include?(PaperSubscription.normalize_name(names[index])) }
      seed_names = subscription.seed_paper.authorships.pluck(:display_name) - [ subscription.display_name ]
      match.evidence = {
        "authors" => names, "positions" => positions, "author_count" => names.length,
        "query_names" => @run.name_variants, "version" => result.raw_metadata["version"], "run_id" => @run.id,
        "common_authors" => names & seed_names, "observed_at" => Time.current.iso8601
      }
      # Existing human decisions survive new queries and paper revisions.
      match.save!
    end
  end

  private

  def integer_value(node)
    value = node&.text.to_s
    raise FetchError, "arXiv 返回缺失或无效的分页信息" unless value.match?(/\A\d+\z/)

    value.to_i
  end
end
