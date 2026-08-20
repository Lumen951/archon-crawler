module Tools
  class ListTagsTool < MCP::Tool
    tool_name "list_tags"
    description "列出所有标签及其关联账号数量。用于了解现有的分类标签体系。"
    annotations(read_only_hint: true, destructive_hint: false)

    AVAILABLE_FIELDS = %w[id name color description accounts_count].freeze

    input_schema(
      properties: {
        keyword: { type: "string", description: "按标签名称搜索" },
        fields: { type: "array", items: { type: "string" }, description: "只返回指定字段（可选值：#{AVAILABLE_FIELDS.join('、')}），不传则返回全部字段。" },
      }
    )

    def self.call(server_context:, keyword: nil, fields: nil)
      scope = Tag.ordered

      if keyword.present?
        scope = scope.search(keyword)
      end

      requested_fields = fields&.map { |f| f.to_s.to_sym }

      result = {
        tags: scope.map { |t|
          full = {
            id: t.id,
            name: t.name,
            color: t.color,
            description: t.description,
            accounts_count: t.tag_accounts_count,
          }
          requested_fields ? full.slice(*requested_fields) : full
        }
      }

      MCP::Tool::Response.new([{ type: "text", text: result.to_json }])
    end
  end
end
