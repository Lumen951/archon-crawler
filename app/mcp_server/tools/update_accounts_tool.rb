module Tools
  class UpdateAccountsTool < MCP::Tool
    tool_name "update_accounts"
    description "批量操作账号：启用/停用账号、添加/移除标签。用于分析后批量管理账号。"
    annotations(read_only_hint: false, destructive_hint: true)

    input_schema(
      properties: {
        account_ids: { type: "array", items: { type: "integer" }, description: "要操作的账号 ID 列表" },
        status: { type: "string", enum: %w[active inactive], description: "设置状态（active=启用, inactive=停用）" },
        add_tag_ids: { type: "array", items: { type: "integer" }, description: "要添加的标签 ID 列表" },
        remove_tag_ids: { type: "array", items: { type: "integer" }, description: "要移除的标签 ID 列表" },
        add_tag_names: { type: "array", items: { type: "string" }, description: "要添加的标签名称（不存在则自动创建）" },
      },
      required: ["account_ids"]
    )

    def self.call(server_context:, account_ids:, status: nil, add_tag_ids: nil, remove_tag_ids: nil, add_tag_names: nil)
      if account_ids.blank?
        return MCP::Tool::Response.new(
          [{ type: "text", text: "account_ids 不能为空" }],
          error: true
        )
      end

      accounts = Account.where(id: account_ids)

      if accounts.empty?
        return MCP::Tool::Response.new(
          [{ type: "text", text: "未找到指定的账号" }],
          error: true
        )
      end

      results = { updated: 0, errors: [] }

      # Update status
      if status.present?
        unless %w[active inactive].include?(status.to_s)
          return MCP::Tool::Response.new(
            [{ type: "text", text: "无效的 status: #{status}" }],
            error: true
          )
        end
        count = accounts.update_all(status: status)
        results[:status_updated] = count
      end

      # Add tags by ID
      if add_tag_ids.present?
        add_tag_ids.each do |tag_id|
          tag = Tag.find_by(id: tag_id)
          if tag.nil?
            results[:errors] << "标签 ID #{tag_id} 不存在"
            next
          end
          accounts.each do |account|
            TagAccount.find_or_create_by!(account: account, tag: tag)
          end
        end
        results[:tags_added_by_id] = add_tag_ids.length
      end

      # Add tags by name (auto-create if not exists)
      if add_tag_names.present?
        add_tag_names.each do |tag_name|
          tag = Tag.find_or_create_by_name(tag_name)
          if tag.persisted?
            accounts.each do |account|
              TagAccount.find_or_create_by!(account: account, tag: tag)
            end
          else
            results[:errors] << "创建标签 '#{tag_name}' 失败: #{tag.errors.full_messages.join(', ')}"
          end
        end
        results[:tags_added_by_name] = add_tag_names.length
      end

      # Remove tags by ID
      if remove_tag_ids.present?
        count = TagAccount.where(account_id: account_ids, tag_id: remove_tag_ids).destroy_all.length
        results[:tags_removed] = count
      end

      results[:total_accounts] = accounts.count

      MCP::Tool::Response.new([{ type: "text", text: results.to_json }])
    end
  end
end
