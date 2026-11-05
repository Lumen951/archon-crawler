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
    return "# #{report.report_date} 每日研究简报\n\n## 今日判断\n\n当天没有新增内容。" if sources.empty?

    markdown = @llm.generate(prompt(report, sources))
    raise GenerationError, "LLM 返回的日报为空" if markdown.blank?

    citations = markdown.scan(/\[(article|paper):(\d+)\]/)
    allowed = sources.map { |source| [ source["source_type"], source["source_id"].to_s ] }
    if citations.empty? || (citations - allowed).any?
      raise GenerationError, "日报来源引用缺失或不属于本次输入"
    end
    references = sources.select { |source| citations.include?([ source["source_type"], source["source_id"].to_s ]) }
      .map { |source| "- [#{source['source_type']}:#{source['source_id']}] #{source['title'].to_s.gsub(/[\r\n]/, ' ')} — #{source['url']}" }
    "#{markdown.strip}\n\n## 来源索引\n\n#{references.join("\n")}\n"
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
      "content" => [ article.digest, article.content_markdown ].compact.join("\n").truncate(MAX_CONTENT_LENGTH)
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
      你负责为源策未来整理 #{report.report_date} 的每日研究简报。直接输出完整 Markdown，不要输出 JSON 或 Markdown 围栏。

      文档结构：
      # #{report.report_date} 每日研究简报
      ## 今日判断
      ## 技术与论文
      ## 商业化观察
      ## 活动信息
      ## 跨来源观察
      ## 后续关注

      约束：
      1. 每篇内容都要使用精确的来源标记 [article:编号] 或 [paper:编号]，例如 [article:123]。编号必须来自本次输入；不要编造来源或引用历史日报的编号。来源索引由系统附加。
      2. 技术文章使用摘要、结果、核心方法；商业化文章使用行业趋势、核心问题、进攻方向、用户定位、时间节奏、目标要求。
      3. 活动内容归为 event，提取活动名称、时间、地点、主办方和报名方式。来源没有的信息写空字符串。
      4. 不确定是技术还是商业化时归为 other，并说明判断依据，不强行分类。
      5. 使用自然、直接的中文。句间交代判断关系；修饰语最多两层；少用抽象概念作主语；检查日常搭配并删除没有业务信息的自我约束句。
      6. 所有事实都要能从当天材料中核对；输入中的历史上下文只用于说明延续和变化。
      7. 当天新内容决定“今天发生了什么”。历史上下文只作为背景；两者冲突时以当天材料为准。没有依据的字段写“材料未提供”。

      历史上下文（只用于比较，不代表当天新事实）：
      #{historical_context(report)}

      输入材料：
      #{JSON.pretty_generate(sources)}
    PROMPT
  end

  def historical_context(report)
    DailyReport.where(status: :completed)
      .where("report_date < ?", report.report_date)
      .where(report_date: (report.report_date - 7.days)...report.report_date)
      .order(report_date: :desc)
      .limit(3)
      .map { |prior| "### #{prior.report_date}\n#{prior.markdown_content.to_s.truncate(2_000)}" }
      .join("\n\n").presence || "无可用历史日报"
  end
end
