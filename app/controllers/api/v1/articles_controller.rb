module Api
  module V1
    class ArticlesController < Api::BaseController
      # GET /api/v1/articles
      # Supports three modes:
      #   1. By groups: ?group_ref_keys[]=key1&group_ref_keys[]=key2&start_date=2026-08-01&end_date=2026-08-19
      #   2. By account: ?account_id=123&start_date=2026-08-01&end_date=2026-08-19
      #   3. Global keyword search: ?keyword=term&platform=wechat&start_date=2026-08-01
      def index
        if params[:account_id].present?
          index_by_account
        elsif params[:group_ref_keys].present?
          index_by_group
        elsif params[:keyword].present?
          index_by_keyword
        else
          index_by_group
        end
      end

      private

      # Mode 2: Query articles by account_id with date range
      def index_by_account
        account = Account.find(params[:account_id])

        page, per_page = pagination_params

        scope = account.articles.order(published_at: :desc)

        # Keyword fuzzy search (title / digest / content_markdown)
        scope = scope.search_keyword(params[:keyword])

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

      # Mode 3: Global keyword search. This intentionally does not require an
      # account or group, mirroring the MCP search_articles tool.
      def index_by_keyword
        page, per_page = pagination_params
        scope = Article.order(published_at: :desc).search_keyword(params[:keyword])

        if params[:platform].present?
          account_type = platform_account_type(params[:platform])
          return unless account_type

          scope = scope.joins(:account).where(accounts: { type: account_type })
        end

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

        articles = scope.includes(:account).page(page).per(per_page)

        render json: {
          keyword: params[:keyword],
          articles: articles.map { |article|
            {
              id: article.id,
              title: article.title,
              url: article.url,
              digest: article.best_digest,
              content: article.clean_content_markdown,
              published_at: article.published_at&.iso8601,
              account: {
                id: article.account.id,
                fakeid: article.account.fakeid,
                nickname: article.account.nickname,
                platform: article.account.type.sub("Account", "").downcase
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

      # Mode 1: Original group-based query
      def index_by_group
        group_ref_keys = params[:group_ref_keys] || []
        source = params[:source].to_s.strip.presence
        page, per_page = pagination_params

        # Validate parameters
        if group_ref_keys.empty?
          render json: { error: "group_ref_keys 不能为空（或使用 account_id 模式）" }, status: :bad_request
          return
        end

        if params[:start_date].blank? || params[:end_date].blank?
          render json: { error: "start_date 和 end_date 不能为空" }, status: :bad_request
          return
        end

        begin
          range_start = Date.parse(params[:start_date]).beginning_of_day
          range_end = Date.parse(params[:end_date]).end_of_day
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
          account_type = platform_account_type(source)
          return unless account_type

          articles = articles.joins("INNER JOIN accounts ON accounts.id = articles.account_id")
                             .where(accounts: { type: account_type })
        end

        # Keyword fuzzy search (title / digest / content_markdown)
        articles = articles.search_keyword(params[:keyword])

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

      def platform_account_type(platform)
        {
          "wechat" => "WechatAccount",
          "rednote" => "RednoteAccount",
          "twitter" => "TwitterAccount",
          "website" => "WebsiteAccount"
        }[platform.to_s.downcase].tap { |account_type|
          unless account_type
            render json: { error: "不支持的平台: #{platform}" }, status: :bad_request
          end
        }
      end
    end
  end
end
