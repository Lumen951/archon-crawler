module Tools
  class BatchUpdateAccountsByFilterTool < MCP::Tool
    tool_name "batch_update_accounts_by_filter"
    description "按过滤条件批量更新账号（打标签/改状态/移除标签），无需先列出再操作。直接在服务端完成，避免传输大量中间数据。支持 dry_run 预览匹配数量。"
    annotations(read_only_hint: false, destructive_hint: true)

    input_schema(
      properties: {
        filter: {
          type: "object",
          description: "过滤条件（与 list_accounts 一致），为空则匹配所有账号",
          properties: {
            platform: { type: "string", enum: %w[wechat rednote twitter], description: "按平台过滤" },
            status: { type: "string", enum: %w[active inactive], description: "按状态过滤" },
            activity_level: { type: "string", enum: %w[active slow dormant dead never uncrawled], description: "按活跃度过滤" },
            tag_id: { type: "integer", description: "按标签 ID 过滤（仅匹配已打该标签的账号）" },
            keyword: { type: "string", description: "按账号名称搜索" },
          },
        },
        status: { type: "string", enum: %w[active inactive], description: "设置状态（active=启用, inactive=停用）" },
        add_tag_ids: { type: "array", items: { type: "integer" }, description: "要添加的标签 ID 列表" },
        add_tag_names: { type: "array", items: { type: "string" }, description: "要添加的标签名称（不存在则自动创建）" },
        remove_tag_ids: { type: "array", items: { type: "integer" }, description: "要移除的标签 ID 列表" },
        dry_run: { type: "boolean", description: "仅返回匹配的账号数量，不实际执行更新（默认 false）" },
      },
    )

    def self.call(server_context:, filter: nil, status: nil, add_tag_ids: nil, add_tag_names: nil, remove_tag_ids: nil, dry_run: false)
      # Build scope from filter
      scope = apply_filter(filter)

      if dry_run
        count = scope.count
        return MCP::Tool::Response.new([{
          type: "text",
          text: { dry_run: true, matched_accounts: count }.to_json
        }])
      end

      # Validate at least one operation is specified
      if status.blank? && add_tag_ids.blank? && add_tag_names.blank? && remove_tag_ids.blank?
        return MCP::Tool::Response.new(
          [{ type: "text", text: "请至少指定一个操作：status / add_tag_ids / add_tag_names / remove_tag_ids" }],
          error: true
        )
      end

      results = { matched_accounts: 0, operations: {} }

      # Status update
      if status.present?
        unless %w[active inactive].include?(status.to_s)
          return MCP::Tool::Response.new(
            [{ type: "text", text: "无效的 status: #{status}" }],
            error: true
          )
        end
        count = scope.update_all(status: status)
        results[:operations][:status_updated] = count
      end

      # Add tags by ID
      if add_tag_ids.present?
        added = 0
        errors = []
        add_tag_ids.each do |tag_id|
          tag = Tag.find_by(id: tag_id)
          if tag.nil?
            errors << "标签 ID #{tag_id} 不存在"
            next
          end
          scope.find_each do |account|
            TagAccount.find_or_create_by!(account: account, tag: tag)
            added += 1
          rescue ActiveRecord::RecordNotUnique
            # already tagged, skip
          end
        end
        results[:operations][:tags_added_by_id] = added
        results[:operations][:tag_id_errors] = errors if errors.any?
      end

      # Add tags by name (auto-create)
      if add_tag_names.present?
        added = 0
        errors = []
        add_tag_names.each do |tag_name|
          tag = Tag.find_or_create_by_name(tag_name)
          if tag.persisted?
            scope.find_each do |account|
              TagAccount.find_or_create_by!(account: account, tag: tag)
              added += 1
            rescue ActiveRecord::RecordNotUnique
              # already tagged, skip
            end
          else
            errors << "创建标签 '#{tag_name}' 失败: #{tag.errors.full_messages.join(', ')}"
          end
        end
        results[:operations][:tags_added_by_name] = added
        results[:operations][:tag_name_errors] = errors if errors.any?
      end

      # Remove tags by ID
      if remove_tag_ids.present?
        account_ids = scope.pluck(:id)
        count = TagAccount.where(account_id: account_ids, tag_id: remove_tag_ids).destroy_all.length
        results[:operations][:tags_removed] = count
      end

      results[:matched_accounts] = scope.count

      MCP::Tool::Response.new([{ type: "text", text: results.to_json }])
    end

    private

    def self.apply_filter(filter)
      scope = Account.all
      return scope if filter.blank?

      f = filter.with_indifferent_access

      if f[:platform].present?
        account_type = case f[:platform].to_s.downcase
                       when "wechat"   then "WechatAccount"
                       when "rednote"  then "RednoteAccount"
                       when "twitter"  then "TwitterAccount"
                       else nil
                       end
        scope = scope.where(type: account_type) if account_type
      end

      if f[:status].present?
        scope = scope.where(status: f[:status]) if %w[active inactive].include?(f[:status].to_s)
      end

      if f[:activity_level].present?
        scope = scope.by_activity_level(f[:activity_level]) if %w[active slow dormant dead never uncrawled].include?(f[:activity_level].to_s)
      end

      if f[:tag_id].present?
        scope = scope.with_tag(f[:tag_id])
      end

      if f[:keyword].present?
        scope = scope.where("nickname ILIKE ?", "%#{Account.sanitize_sql_like(f[:keyword])}%")
      end

      scope
    end
  end
end
