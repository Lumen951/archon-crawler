module Tools
  class ListTagsTool < MCP::Tool
    tool_name "list_tags"
    description "列出所有标签及其关联账号数量。用于了解现有的分类标签体系。"
    annotations(read_only_hint: true, destructive_hint: false)

    input_schema(
      properties: {
        keyword: { type: "string", description: "按标签名称搜索" },
      }
    )

    def self.call(server_context:, keyword: nil)
      scope = Tag.ordered

      if keyword.present?
        scope = scope.search(keyword)
      end

      result = {
        tags: scope.map { |t|
          {
            id: t.id,
            name: t.name,
            color: t.color,
            description: t.description,
            accounts_count: t.tag_accounts_count,
          }
        }
      }

      MCP::Tool::Response.new([{ type: "text", text: result.to_json }])
    end
  end
end
