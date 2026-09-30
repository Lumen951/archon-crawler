module Tools
  class SearchArticlesTool < MCP::Tool
    tool_name "search_articles"
    description "跨账号全局搜索文章，按关键词模糊匹配标题、摘要和正文。可按平台和日期范围过滤，用于按主题或内容查找文章。"
    annotations(read_only_hint: true, destructive_hint: false)

    ARTICLE_FIELDS = %w[id title url published_at digest content].freeze

    PLATFORM_ACCOUNT_TYPES = {
      "wechat" => "WechatAccount",
      "rednote" => "RednoteAccount",
      "twitter" => "TwitterAccount",
      "website" => "WebsiteAccount"
    }.freeze

    input_schema(
      properties: {
        keyword: { type: "string", description: "搜索关键词，匹配标题、摘要或正文，多个词用空格分隔（AND 语义）" },
        platform: { type: "string", enum: PLATFORM_ACCOUNT_TYPES.keys, description: "平台过滤（可选）" },
        start_date: { type: "string", description: "起始日期（YYYY-MM-DD）" },
        end_date: { type: "string", description: "结束日期（YYYY-MM-DD）" },
        fields: { type: "array", items: { type: "string" }, description: "只返回指定文章字段（可选值：#{ARTICLE_FIELDS.join('、')}），不传则返回除 content 外的全部字段。content 较大，仅在需要时传入。" },
        page: { type: "integer", description: "页码（默认 1）" },
        per_page: { type: "integer", description: "每页数量（默认 25，最大 100）" }
      },
      required: [ "keyword" ]
    )

    def self.call(server_context:, keyword:, platform: nil, start_date: nil, end_date: nil, fields: nil, page: 1, per_page: 25)
      if keyword.blank?
        return MCP::Tool::Response.new(
          [ { type: "text", text: "keyword 不能为空" } ],
          error: true
        )
      end

      scope = Article.order(published_at: :desc).search_keyword(keyword)

      if platform.present?
        account_type = PLATFORM_ACCOUNT_TYPES[platform.to_s.downcase]
        if account_type.nil?
          return MCP::Tool::Response.new(
            [ { type: "text", text: "不支持的平台: #{platform}，可选：#{PLATFORM_ACCOUNT_TYPES.keys.join('、')}" } ],
            error: true
          )
        end
        scope = scope.joins(:account).where(accounts: { type: account_type })
      end

      if start_date.present?
        begin
          scope = scope.where("published_at >= ?", Date.parse(start_date).beginning_of_day)
        rescue Date::Error
          return MCP::Tool::Response.new(
            [ { type: "text", text: "start_date 格式无效，请使用 YYYY-MM-DD" } ],
            error: true
          )
        end
      end

      if end_date.present?
        begin
          scope = scope.where("published_at <= ?", Date.parse(end_date).end_of_day)
        rescue Date::Error
          return MCP::Tool::Response.new(
            [ { type: "text", text: "end_date 格式无效，请使用 YYYY-MM-DD" } ],
            error: true
          )
        end
      end

      page = [ [ page.to_i, 1 ].max ].min
      per_page = [ [ per_page.to_i, 25 ].max, 100 ].min

      requested_fields = fields&.map { |f| f.to_s.to_sym }
      want_content = requested_fields&.include?(:content)

      articles = scope.includes(:account).page(page).per(per_page)

      result = {
        keyword: keyword,
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
            account: {
              id: a.account.id,
              fakeid: a.account.fakeid,
              nickname: a.account.nickname,
              platform: a.account.type.sub("Account", "").downcase
            }
          }
          requested_fields ? full.slice(*requested_fields) : full.except(:content)
        }
      }

      MCP::Tool::Response.new([ { type: "text", text: result.to_json } ])
    end
  end
end
