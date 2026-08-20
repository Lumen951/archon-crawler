module Tools
  class ListAccountsTool < MCP::Tool
    tool_name "list_accounts"
    description "列出所有账号，支持按平台、状态、活跃度、标签、关键词过滤和分页。用于浏览、搜索或筛选公众号/小红书/Twitter 账号。"
    annotations(read_only_hint: true, destructive_hint: false)

    AVAILABLE_FIELDS = %w[id fakeid nickname platform status activity_level activity_score
                          total_articles articles_last_7_days articles_last_30_days
                          last_published_at tags].freeze

    input_schema(
      properties: {
        platform: { type: "string", enum: %w[wechat rednote twitter], description: "按平台过滤" },
        status: { type: "string", enum: %w[active inactive], description: "按状态过滤" },
        activity_level: { type: "string", enum: %w[active slow dormant dead never uncrawled], description: "按活跃度过滤" },
        tag_id: { type: "integer", description: "按标签 ID 过滤" },
        keyword: { type: "string", description: "按账号名称搜索" },
        fields: { type: "array", items: { type: "string" }, description: "只返回指定字段（可选值：#{AVAILABLE_FIELDS.join('、')}），不传则返回全部字段。用于减少返回数据量。" },
        page: { type: "integer", description: "页码（默认 1）" },
        per_page: { type: "integer", description: "每页数量（默认 25，最大 100）" },
      }
    )

    def self.call(server_context:, platform: nil, status: nil, activity_level: nil, tag_id: nil, keyword: nil, fields: nil, page: 1, per_page: 25)
      scope = Account.all

      # Platform filter
      if platform.present?
        account_type = case platform.to_s.downcase
                       when "wechat"   then "WechatAccount"
                       when "rednote"  then "RednoteAccount"
                       when "twitter"  then "TwitterAccount"
                       else
                         return MCP::Tool::Response.new(
                           [{ type: "text", text: "不支持的平台: #{platform}" }],
                           error: true
                         )
                       end
        scope = scope.where(type: account_type)
      end

      # Status filter
      if status.present?
        unless %w[active inactive].include?(status.to_s)
          return MCP::Tool::Response.new(
            [{ type: "text", text: "无效的 status: #{status}" }],
            error: true
          )
        end
        scope = scope.where(status: status)
      end

      # Activity level filter
      if activity_level.present?
        unless %w[active slow dormant dead never uncrawled].include?(activity_level.to_s)
          return MCP::Tool::Response.new(
            [{ type: "text", text: "无效的 activity_level: #{activity_level}" }],
            error: true
          )
        end
        scope = scope.by_activity_level(activity_level)
      end

      # Tag filter
      if tag_id.present?
        scope = scope.with_tag(tag_id)
      end

      # Keyword search
      if keyword.present?
        scope = scope.where("nickname ILIKE ?", "%#{Account.sanitize_sql_like(keyword)}%")
      end

      # Pagination
      page = [[page.to_i, 1].max].min
      per_page = [[per_page.to_i, 25].max, 100].min

      # Validate fields
      requested_fields = fields&.map(&:to_s)&.intersection(AVAILABLE_FIELDS)
      # Skip tags eager loading when not needed
      need_tags = requested_fields.nil? || requested_fields.include?("tags")

      accounts = scope
      accounts = accounts.includes(:tags) if need_tags
      accounts = accounts.order(activity_score: :desc, nickname: :asc)
                         .page(page)
                         .per(per_page)

      result = {
        total_count: accounts.total_count,
        page: accounts.current_page,
        per_page: accounts.limit_value,
        total_pages: accounts.total_pages,
        accounts: accounts.map { |a|
          full = {
            id: a.id,
            fakeid: a.fakeid,
            nickname: a.nickname,
            platform: a.type.sub("Account", "").downcase,
            status: a.status,
            activity_level: a.activity_level.to_s,
            activity_score: a.activity_score,
            total_articles: a.total_articles,
            articles_last_7_days: a.articles_last_7_days,
            articles_last_30_days: a.articles_last_30_days,
            last_published_at: a.last_published_at&.iso8601,
            tags: need_tags ? a.tags.map { |t| { id: t.id, name: t.name, color: t.color } } : nil,
          }
          requested_fields ? full.slice(*requested_fields) : full
        }
      }

      MCP::Tool::Response.new([{ type: "text", text: result.to_json }])
    end
  end
end
