module Api
  module V1
    # 活动调研数据（只读）。调研结果 JSON 存在 EventResearchRun.result，
    # 这里原样输出，不加工 —— 报告由使用方基于数据自行生成。
    class EventResearchRunsController < BaseController
      # GET /api/v1/event_research_runs
      #
      # Filters:
      #   account_id — 只看某个活动账号
      #   status     — pending / running / completed / failed
      #   latest     — "true" 时只返回每个账号最近一次成功调研（忽略 status）
      def index
        account_scope = EventResearchRun.all
        account_scope = account_scope.where(account_id: params[:account_id]) if params[:account_id].present?

        if params[:latest] == "true"
          scope = EventResearchRun.where(id: latest_completed_ids(account_scope)).recent.includes(:account)
        else
          scope = account_scope.recent.includes(:account)

          if params[:status].present?
            unless EventResearchRun.statuses.key?(params[:status])
              return render json: { error: "无效的 status，可选值：#{EventResearchRun.statuses.keys.join('、')}" }, status: :bad_request
            end

            scope = scope.where(status: params[:status])
          end
        end

        page = [ params[:page].to_i, 1 ].max
        per_page = [ [ params[:per_page].to_i, 25 ].max, 100 ].min
        runs = scope.page(page).per(per_page)

        render json: {
          event_research_runs: runs.map { |run| run_json(run) },
          pagination: {
            page: runs.current_page,
            per_page: runs.limit_value,
            total_count: runs.total_count,
            total_pages: runs.total_pages
          }
        }
      end

      # GET /api/v1/event_research_runs/:id — 含完整 result JSON
      def show
        run = EventResearchRun.find(params[:id])

        render json: { event_research_run: run_json(run, include_result: true) }
      end

      private

      def run_json(run, include_result: false)
        data = {
          id: run.id,
          account: {
            id: run.account.id,
            nickname: run.account.nickname,
            type: run.account.type
          },
          status: run.status,
          refresh_cache: run.refresh_cache,
          people_count: run.people_count,
          award_count: run.award_count,
          company_count: run.company_count,
          error_message: run.error_message,
          started_at: run.started_at&.iso8601,
          completed_at: run.completed_at&.iso8601,
          created_at: run.created_at.iso8601
        }
        data[:result] = run.result if include_result
        data
      end

      # DISTINCT ON (account_id) 取每个账号最近一次成功调研。
      # Postgres 要求 DISTINCT ON 的排序列在最前，所以从干净的关系上构建。
      def latest_completed_ids(account_scope)
        EventResearchRun.where(status: :completed)
                        .where(account_id: account_scope.select(:account_id))
                        .order(:account_id, created_at: :desc)
                        .select("DISTINCT ON (account_id) id")
                        .map(&:id)
      end
    end
  end
end
