module Api
  module V1
    class AccountsController < Api::BaseController
      # GET /api/v1/accounts
      # List accounts with filters, pagination
      def index
        scope = Account.all

        # Platform filter
        if params[:platform].present?
          account_type = platform_type_from_param(params[:platform])
          return if performed?
          scope = scope.where(type: account_type)
        end

        # Status filter
        if params[:status].present?
          unless %w[active inactive].include?(params[:status])
            render json: { error: "无效的 status: #{params[:status]}" }, status: :bad_request
            return
          end
          scope = scope.where(status: params[:status])
        end

        # Activity level filter
        if params[:activity_level].present?
          unless %w[active slow dormant dead never uncrawled].include?(params[:activity_level])
            render json: { error: "无效的 activity_level: #{params[:activity_level]}" }, status: :bad_request
            return
          end
          scope = scope.by_activity_level(params[:activity_level])
        end

        # Tag filter
        if params[:tag_id].present?
          scope = scope.with_tag(params[:tag_id])
        end

        # Keyword search
        if params[:keyword].present?
          scope = scope.where("nickname ILIKE ?", "%#{Account.sanitize_sql_like(params[:keyword])}%")
        end

        # Pagination
        page, per_page = pagination_params

        accounts = scope.includes(:tags)
                       .order(activity_score: :desc, nickname: :asc)
                       .page(page)
                       .per(per_page)

        render json: {
          accounts: accounts.map { |a| account_json(a) },
          pagination: {
            page: accounts.current_page,
            per_page: accounts.limit_value,
            total_count: accounts.total_count,
            total_pages: accounts.total_pages
          }
        }
      end

      # GET /api/v1/accounts/:id
      # Show single account detail
      def show
        account = Account.find(params[:id])
        render json: { account: account_json(account, detail: true) }
      end

      # PATCH /api/v1/accounts/:id
      # Update account status and/or tags
      def update
        account = Account.find(params[:id])

        # Update status
        if params[:status].present?
          unless %w[active inactive].include?(params[:status])
            render json: { error: "无效的 status: #{params[:status]}" }, status: :bad_request
            return
          end
          account.update!(status: params[:status])
        end

        # Replace tags
        if params[:tag_ids].present?
          account.tag_accounts.destroy_all
          params[:tag_ids].each do |tag_id|
            tag = Tag.find(tag_id)
            TagAccount.find_or_create_by!(account: account, tag: tag)
          end
        end

        # Incremental tag operations
        if params[:add_tag_ids].present?
          params[:add_tag_ids].each do |tag_id|
            tag = Tag.find(tag_id)
            TagAccount.find_or_create_by!(account: account, tag: tag)
          end
        end

        if params[:remove_tag_ids].present?
          account.tag_accounts.where(tag_id: params[:remove_tag_ids]).destroy_all
        end

        account.reload
        render json: { account: account_json(account, detail: true) }
      end

      # POST /api/v1/accounts/bulk_update
      # Batch update accounts
      def bulk_update
        ids = params[:ids]
        if ids.blank? || !ids.is_a?(Array)
          render json: { error: "ids 必须是非空数组" }, status: :bad_request
          return
        end

        accounts = Account.where(id: ids)
        updated = 0

        # Update status
        if params[:status].present?
          unless %w[active inactive].include?(params[:status])
            render json: { error: "无效的 status: #{params[:status]}" }, status: :bad_request
            return
          end
          updated = accounts.update_all(status: params[:status])
        end

        # Add tags
        if params[:add_tag_ids].present?
          params[:add_tag_ids].each do |tag_id|
            tag = Tag.find(tag_id)
            accounts.each do |account|
              TagAccount.find_or_create_by!(account: account, tag: tag)
            end
          end
        end

        # Remove tags
        if params[:remove_tag_ids].present?
          TagAccount.where(account_id: ids, tag_id: params[:remove_tag_ids]).destroy_all
        end

        render json: {
          updated_count: accounts.count,
          account_ids: ids
        }
      end

      # Legacy lookup endpoint (kept for backward compatibility)
      # GET /api/v1/accounts/lookup?source=wechat&id=xxx
      def lookup
        source = params[:source].to_s.strip.presence
        id = params[:id].to_s.strip.presence
        name = params[:name].to_s.strip.presence

        if source.blank?
          render json: { error: "source 不能为空（wechat/rednote/twitter）" }, status: :bad_request
          return
        end

        unless %w[wechat rednote twitter].include?(source.downcase)
          render json: { error: "不支持的平台: #{source}" }, status: :bad_request
          return
        end

        if id.blank? && name.blank?
          render json: { error: "至少需要提供 id 或 name 参数" }, status: :bad_request
          return
        end

        result = AccountResolver.resolve(source: source, id: id, name: name)

        if result.accounts.any?
          render json: {
            source: source.downcase,
            accounts: result.accounts.map { |a|
              {
                id: a.fakeid,
                name: a.nickname,
                round_head_img: a.round_head_img
              }
            },
            status: result.status
          }
        else
          render json: {
            source: source.downcase,
            id: id,
            name: name,
            accounts: [],
            status: result.status,
            error: result.error
          }, status: :not_found
        end
      end

      private

      def platform_type_from_param(platform)
        case platform.to_s.downcase
        when "wechat"   then "WechatAccount"
        when "rednote"  then "RednoteAccount"
        when "twitter"  then "TwitterAccount"
        when "website"  then "WebsiteAccount"
        else
          render json: { error: "不支持的平台: #{platform}" }, status: :bad_request
          nil
        end
      end

      def account_json(account, detail: false)
        json = {
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
          tags: account.tags.map { |t| { id: t.id, name: t.name, color: t.color } },
          avatar_url: account.round_head_img
        }

        if detail
          json[:twitter_screen_name] = account.twitter_screen_name if account.twitter?
          json[:next_crawl_at] = account.next_crawl_at&.iso8601
          json[:created_at] = account.created_at&.iso8601
          json[:updated_at] = account.updated_at&.iso8601

          # Recent articles summary
          json[:recent_articles] = account.articles
            .order(published_at: :desc)
            .limit(5)
            .map { |a| { id: a.id, title: a.title, published_at: a.published_at&.iso8601, url: a.url } }
        end

        json
      end
    end
  end
end
