module Tools
  class GetAccountTool < MCP::Tool
    tool_name "get_account"
    description "获取单个账号的详细信息，包含活动统计、标签、最近文章摘要。用于深入了解某个公众号/小红书/Twitter 账号。"
    annotations(read_only_hint: true, destructive_hint: false)

    AVAILABLE_FIELDS = %w[id fakeid nickname platform status activity_level activity_score
                          total_articles articles_last_7_days articles_last_30_days
                          last_published_at last_crawled_at next_crawl_at created_at
                          tags avatar_url recent_articles].freeze

    input_schema(
      properties: {
        account_id: { type: "integer", description: "账号 ID" },
        fields: { type: "array", items: { type: "string" }, description: "只返回指定字段（可选值：#{AVAILABLE_FIELDS.join('、')}），不传则返回全部字段。" },
        include_articles: { type: "boolean", description: "是否包含最近文章（默认 true）。设为 false 可大幅减少返回数据量。" },
        articles_limit: { type: "integer", description: "最近文章数量（默认 10，最大 20）" },
      },
      required: ["account_id"]
    )

    def self.call(server_context:, account_id:, fields: nil, include_articles: true, articles_limit: 10)
      account = Account.find_by(id: account_id)

      if account.nil?
        return MCP::Tool::Response.new(
          [{ type: "text", text: "未找到 ID 为 #{account_id} 的账号" }],
          error: true
        )
      end

      requested_fields = fields&.map { |f| f.to_s.to_sym }
      want_articles = include_articles != false && (requested_fields.nil? || requested_fields.include?(:recent_articles))
      articles_limit = [[articles_limit.to_i, 1].max, 20].min

      full = {
        id: account.id,
        fakeid: account.fakeid,
        nickname: account.nickname,
        platform: account.type.sub("Account", "").downcase,
        status: account.status,
        activity_level: account.activity_level.to_s,
        activity_score: account.activity_score,
        total_articles: account.total_articles,
        articles_last_7_days: account.articles_last_7_days,
        articles_last_30_days: account.articles_last_30_days,
        last_published_at: account.last_published_at&.iso8601,
        last_crawled_at: account.last_crawled_at&.iso8601,
        next_crawl_at: account.next_crawl_at&.iso8601,
        created_at: account.created_at&.iso8601,
        tags: account.tags.map { |t| { id: t.id, name: t.name, color: t.color } },
        avatar_url: account.round_head_img,
        recent_articles: want_articles ? account.articles
          .order(published_at: :desc)
          .limit(articles_limit)
          .map { |a|
            {
              id: a.id,
              title: a.title,
              url: a.url,
              published_at: a.published_at&.iso8601,
              digest: a.best_digest,
            }
          } : nil,
      }

      result = requested_fields ? full.slice(*requested_fields) : full

      MCP::Tool::Response.new([{ type: "text", text: result.to_json }])
    end
  end
end
