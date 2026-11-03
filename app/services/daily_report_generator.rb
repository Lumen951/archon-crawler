class DailyReportGenerator
  MAX_SOURCES = 80
  MAX_CONTENT_LENGTH = 4_000

  class GenerationError < StandardError; end

  def initialize(llm: LlmClient.new)
    @llm = llm
  end

  def call(report)
    articles = articles_for(report).limit(MAX_SOURCES)
    papers = Paper.where(created_at: report.window_start...report.window_end)
      .order(:created_at, :id).limit([ MAX_SOURCES - articles.length, 0 ].max)
    sources = articles.map { |article| article_source(article) } + papers.map { |paper| paper_source(paper) }

    report.update!(article_count: articles.length, paper_count: papers.length)
    return { "items" => [] } if sources.empty?

    validate_response(@llm.generate_json(prompt(report, sources)), sources)
  rescue LlmClient::ApiError, JSON::ParserError => e
    raise GenerationError, e.message
  end

  private

  def articles_for(report)
    day_articles = Article.where(created_at: report.window_start...report.window_end)
    event_articles = Article.joins(:account)
      .where(accounts: { type: "WebsiteAccount" })
      .where("accounts.metadata ->> 'monitoring_group' = ?", "event_sources")
      .where(created_at: report.window_end...Time.current)

    Article.where(id: day_articles.select(:id))
      .or(Article.where(id: event_articles.select(:id)))
      .includes(:account).order(:created_at, :id).limit(MAX_SOURCES)
  end

  def article_source(article)
    event = article.account.is_a?(WebsiteAccount) && article.account.metadata["monitoring_group"] == "event_sources"
    {
      "source_type" => "article",
      "source_id" => article.id,
      "kind_hint" => event ? "event" : nil,
      "title" => article.title,
      "url" => article.url,
      "author" => article.author,
      "account" => article.account.nickname,
      "published_at" => article.published_at&.iso8601,
      "content" => [article.digest, article.content_markdown].compact.join("\n").truncate(MAX_CONTENT_LENGTH)
    }
  end

  def paper_source(paper)
    {
      "source_type" => "paper",
      "source_id" => paper.id,
      "kind_hint" => "technical",
      "title" => paper.title,
      "url" => paper.primary_source&.canonical_url,
      "published_at" => paper.published_at&.iso8601,
      "content" => paper.abstract.to_s.truncate(MAX_CONTENT_LENGTH)
    }
  end

  def prompt(report, sources)
    <<~PROMPT
      你负责为源策未来整理每日研究简报。报告日期为 #{report.report_date}，按输入材料分类并输出 JSON，不要补充输入中没有的事实。

      输出格式：{"items":[{"source_type":"article或paper","source_id":数字,"kind":"technical、commercial、event或other","title":"标题","summary":"摘要","result":"结果","core_method":"核心方法","industry_trends":"行业趋势","core_question":"核心问题","attack_direction":"进攻方向","user_position":"用户定位","time_rhythm":"时间节奏","goals":"目标要求","event_name":"活动名称","event_time":"活动时间","event_location":"地点","organizer":"主办方","registration":"报名方式","note":"补充判断"}]}

      约束：
      1. 每项必须引用对应输入的 source_type 和 source_id；只返回有分析价值的内容。
      2. 技术文章使用摘要、结果、核心方法；商业化文章使用行业趋势、核心问题、进攻方向、用户定位、时间节奏、目标要求。
      3. 活动内容归为 event，提取活动名称、时间、地点、主办方和报名方式。来源没有的信息写空字符串。
      4. 不确定是技术还是商业化时归为 other，并说明判断依据，不强行分类。
      5. 使用自然、直接的中文。句间交代判断关系；修饰语最多两层；少用抽象概念作主语；检查日常搭配并删除没有业务信息的自我约束句。
      6. 只返回 JSON，不要 Markdown 围栏。所有事实都要能从来源材料中核对。

      输入材料：
      #{JSON.pretty_generate(sources)}
    PROMPT
  end

  def validate_response(response, sources)
    items = response.is_a?(Hash) && response["items"].is_a?(Array) ? response["items"] : nil
    raise GenerationError, "LLM 返回格式无效：缺少 items 数组" unless items

    allowed = sources.index_by { |source| [source["source_type"], source["source_id"]] }
    items.filter_map do |item|
      next unless item.is_a?(Hash)

      key = [item["source_type"], item["source_id"]]
      source = allowed[key]
      next unless source

      result = item.slice(
        "source_type", "source_id", "kind", "title", "summary", "result", "core_method",
        "industry_trends", "core_question", "attack_direction", "user_position",
        "time_rhythm", "goals", "event_name", "event_time", "event_location",
        "organizer", "registration", "note"
      )
      result["kind"] = "other" unless %w[technical commercial event other].include?(result["kind"])
      result.merge("title" => source["title"], "url" => source["url"])
    end
  end
end
