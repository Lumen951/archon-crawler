module Api
  module V1
    class ArticlesController < Api::BaseController
      def index
        group_ref_keys = params[:group_ref_keys] || []
        range = params[:range] || []
        source = params[:source].to_s.strip.presence
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 25).to_i, 100].min

        # Validate parameters
        if group_ref_keys.empty?
          render json: { error: "group_ref_keys 不能为空" }, status: :bad_request
          return
        end

        if range.length != 2
          render json: { error: "range 必须包含两个日期 [start_date, end_date]" }, status: :bad_request
          return
        end

        begin
          range_start = Date.parse(range[0]).beginning_of_day
          range_end = Date.parse(range[1]).end_of_day
        rescue Date::Error
          render json: { error: "日期格式无效，请使用 YYYY-MM-DD 格式" }, status: :bad_request
          return
        end

        # Find groups for current user
        groups = current_user.groups.where(ref_key: group_ref_keys)

        if groups.empty?
          render json: { error: "未找到指定的分组" }, status: :not_found
          return
        end

        # Build query
        # Avoid `articles.*` — it pulls in large columns (e.g. raw_data) that
        # aren't needed in the response, so list only the columns we use.
        articles = Article.joins("INNER JOIN group_accounts ON group_accounts.account_id = articles.account_id")
                          .joins("INNER JOIN groups ON groups.id = group_accounts.group_id")
                          .where(groups: { id: groups })
                          .where(published_at: range_start..range_end)
                          .select(
                            "articles.id, articles.title, articles.digest, articles.url, articles.content_markdown, " \
                            "articles.content_html, articles.published_at, articles.account_id, articles.raw_data, " \
                            "groups.ref_key AS group_ref_key"
                          )

        # Apply platform filter
        if source.present?
          account_type = case source.downcase
                         when "wechat" then "WechatAccount"
                         when "rednote" then "RednoteAccount"
                         when "twitter" then "TwitterAccount"
                         else
                           render json: { error: "不支持的平台: #{source}" }, status: :bad_request
                           return
                         end

          articles = articles.joins("INNER JOIN accounts ON accounts.id = articles.account_id")
                             .where(accounts: { type: account_type })
        end

        # Execute query with pagination
        articles = articles.includes(:account)
                          .order(published_at: :desc)
                          .page(page)
                          .per(per_page)

        # Build response
        render json: {
          articles: articles.map { |article|
            {
              id: article.id,
              title: article.title,
              url: article.url,
              digest: article.best_digest,
              content: article.clean_content_markdown,
              # content_html: article.clean_content_html,
              published_at: article.published_at,
              group_ref_key: article.group_ref_key,
              account: {
                id: article.account.fakeid,
                source: article.account.type.sub("Account", "").downcase,
                name: article.account.nickname
              }
            }
          },
          pagination: {
            page: articles.current_page,
            per_page: articles.limit_value,
            total_count: articles.total_count,
            total_pages: articles.total_pages
          }
        }
      end
    end
  end
end
