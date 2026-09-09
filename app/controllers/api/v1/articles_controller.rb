module Api
  module V1
    class ArticlesController < Api::BaseController
      # GET /api/v1/articles
      # Supports two modes:
      #   1. By groups: ?group_ref_keys[]=key1&group_ref_keys[]=key2&range[]=start&range[]=end
      #   2. By account: ?account_id=123&start_date=2026-08-01&end_date=2026-08-19
      def index
        if params[:account_id].present?
          index_by_account
        else
          index_by_group
        end
      end

      private

      # Mode 2: Query articles by account_id with date range
      def index_by_account
        account = Account.find(params[:account_id])

        page = [params[:page].to_i, 1].max
        per_page = [[params[:per_page].to_i, 25].max, 100].min

        scope = account.articles.order(published_at: :desc)

        # Date range filter
        if params[:start_date].present?
          begin
            scope = scope.where("published_at >= ?", Date.parse(params[:start_date]).beginning_of_day)
          rescue Date::Error
            render json: { error: "start_date 格式无效，请使用 YYYY-MM-DD" }, status: :bad_request
            return
          end
        end

        if params[:end_date].present?
          begin
            scope = scope.where("published_at <= ?", Date.parse(params[:end_date]).end_of_day)
          rescue Date::Error
            render json: { error: "end_date 格式无效，请使用 YYYY-MM-DD" }, status: :bad_request
            return
          end
        end

        articles = scope.page(page).per(per_page)

        render json: {
          account: {
            id: account.id,
            fakeid: account.fakeid,
            nickname: account.nickname,
            platform: account.type.sub("Account", "").downcase
          },
          articles: articles.map { |article|
            {
              id: article.id,
              title: article.title,
              url: article.url,
              digest: article.best_digest,
              content: article.clean_content_markdown,
              published_at: article.published_at&.iso8601
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

      # Mode 1: Original group-based query (unchanged)
      def index_by_group
        group_ref_keys = params[:group_ref_keys] || []
        range = params[:range] || []
        source = params[:source].to_s.strip.presence
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 25).to_i, 100].min

        # Validate parameters
        if group_ref_keys.empty?
          render json: { error: "group_ref_keys 不能为空（或使用 account_id 模式）" }, status: :bad_request
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
                         when "website" then "WebsiteAccount"
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
