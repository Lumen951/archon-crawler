module Tools
  class SearchArticlesTool < MCP::Tool
    tool_name "search_articles"
    description "跨账号全局搜索文章，按关键词模糊匹配标题、摘要和正文。可按平台和日期范围过滤，用于按主题查找文章。"
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
        keyword: { type: "string", description: "搜索关键词，匹配标题、摘要或正文，多个词用空格分隔（AND 语义）；少于 3 个字符的词用不上索引，查询超过 #{Article::SEARCH_TIMEOUT_MS / 1000.0} 秒会被中断并返回提示" },
        platform: { type: "string", enum: PLATFORM_ACCOUNT_TYPES.keys, description: "平台过滤（可选）" },
        start_date: { type: "string", description: "起始日期（YYYY-MM-DD）" },
        end_date: { type: "string", description: "结束日期（YYYY-MM-DD）" },
        fields: { type: "array", items: { type: "string" }, description: "只返回指定文章字段（可选值：#{ARTICLE_FIELDS.join('、')}），不传则返回除 content 外的全部字段。content 较大，仅在需要时传入。" },
        page: { type: "integer", description: "页码（默认 1）" },
        per_page: { type: "integer", description: "每页数量（默认 25，最小 1，最大 100）" }
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
      per_page = per_page.to_i
      per_page = 25 if per_page < 1
      per_page = 100 if per_page > 100

      requested_fields = fields&.map { |f| f.to_s.to_sym }
      want_content = requested_fields&.include?(:content)

      articles = Article.with_search_timeout(keyword) do
        scope.includes(:account).page(page).per(per_page).without_count
      end

      # A term too short for the trigram indexes made the scan run past the cap.
      if articles.nil?
        return MCP::Tool::Response.new(
          [ { type: "text", text: Article.short_search_timeout_message(keyword) } ],
          error: true
        )
      end

      result = {
        keyword: keyword,
        page: articles.current_page,
        per_page: articles.limit_value,
        # No total_count/total_pages: that COUNT has no LIMIT, cannot use the
        # ordering index, and must evaluate the whole trigram OR (16-28s on
        # production). Kaminari instead fetches one extra row on a
        # `without_count` relation, which is what #next_page reads.
        has_next_page: articles.next_page.present?,
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
