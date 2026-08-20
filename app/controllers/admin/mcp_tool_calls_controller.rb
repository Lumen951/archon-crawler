class Admin::McpToolCallsController < Admin::BaseController
  PER_PAGE = 50

  def index
    @q = McpToolCall.ransack(params[:q])
    @q.sorts = "created_at desc" if @q.sorts.blank?

    result = @q.result

    # Summary tiles over the filtered set.
    @total          = result.count
    @error_count    = result.error.count
    @distinct_users = result.distinct.count(:user_id)

    @page = [params[:page].to_i, 1].max
    rows  = result.includes(:user, :api_key)
                  .offset((@page - 1) * PER_PAGE)
                  .limit(PER_PAGE + 1) # one extra row to detect a next page
                  .to_a
    @has_next = rows.size > PER_PAGE
    @mcp_tool_calls = rows.first(PER_PAGE)

    # Filter dropdown options.
    @tool_names = McpToolCall.where.not(tool_name: nil).distinct.order(:tool_name).pluck(:tool_name)
    @methods    = McpToolCall.distinct.order(:method).pluck(:method)
  end

  def show
    @mcp_tool_call = McpToolCall.includes(:user, :api_key).find(params[:id])
  end
end
