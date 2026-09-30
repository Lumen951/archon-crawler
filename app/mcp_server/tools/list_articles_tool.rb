module Tools
  class ListArticlesTool < MCP::Tool
    tool_name "list_articles"
    description "查询某账号的文章列表，支持关键词模糊搜索（标题/摘要/正文）、日期范围过滤和分页。用于分析账号发布内容。"
    annotations(read_only_hint: true, destructive_hint: false)

    ARTICLE_FIELDS = %w[id title url published_at digest content].freeze

    input_schema(
      properties: {
        account_id: { type: "integer", description: "账号 ID" },
        keyword: { type: "string", description: "关键词模糊搜索，匹配标题、摘要或正文，多个词用空格分隔（AND 语义）" },
        start_date: { type: "string", description: "起始日期（YYYY-MM-DD）" },
        end_date: { type: "string", description: "结束日期（YYYY-MM-DD）" },
        fields: { type: "array", items: { type: "string" }, description: "只返回指定文章字段（可选值：#{ARTICLE_FIELDS.join('、')}），不传则返回除 content 外的全部字段。content 较大，仅在需要时传入。" },
        page: { type: "integer", description: "页码（默认 1）" },
        per_page: { type: "integer", description: "每页数量（默认 25，最大 100）" },
      },
      required: ["account_id"]
    )

    def self.call(server_context:, account_id:, keyword: nil, start_date: nil, end_date: nil, fields: nil, page: 1, per_page: 25)
      account = Account.find_by(id: account_id)

      if account.nil?
        return MCP::Tool::Response.new(
          [{ type: "text", text: "未找到 ID 为 #{account_id} 的账号" }],
          error: true
        )
      end

      scope = account.articles.order(published_at: :desc)

      # Keyword fuzzy search (title / digest / body)
      scope = scope.search_keyword(keyword)

      # Date range filter
      if start_date.present?
        begin
          scope = scope.where("published_at >= ?", Date.parse(start_date).beginning_of_day)
        rescue Date::Error
          return MCP::Tool::Response.new(
            [{ type: "text", text: "start_date 格式无效，请使用 YYYY-MM-DD" }],
            error: true
          )
        end
      end

      if end_date.present?
        begin
          scope = scope.where("published_at <= ?", Date.parse(end_date).end_of_day)
        rescue Date::Error
          return MCP::Tool::Response.new(
            [{ type: "text", text: "end_date 格式无效，请使用 YYYY-MM-DD" }],
            error: true
          )
        end
      end

      # Pagination
      page = [[page.to_i, 1].max].min
      per_page = [[per_page.to_i, 25].max, 100].min

      requested_fields = fields&.map { |f| f.to_s.to_sym }
      want_content = requested_fields&.include?(:content)

      articles = scope.page(page).per(per_page)

      result = {
        account: {
          id: account.id,
          fakeid: account.fakeid,
          nickname: account.nickname,
          platform: account.type.sub("Account", "").downcase,
        },
        total_count: articles.total_count,
        page: articles.current_page,
        per_page: articles.limit_value,
        total_pages: articles.total_pages,
        articles: articles.map { |a|
          full = {
            id: a.id,
            title: a.title,
            url: a.url,
            published_at: a.published_at&.iso8601,
            digest: a.best_digest,
            content: want_content ? a.clean_content_markdown : nil,
          }
          requested_fields ? full.slice(*requested_fields) : full.except(:content)
        }
      }

      MCP::Tool::Response.new([{ type: "text", text: result.to_json }])
    end
  end
end
