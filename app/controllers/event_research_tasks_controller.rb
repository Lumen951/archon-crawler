class EventResearchTasksController < ApplicationController
  before_action :require_admin, only: [ :create, :pause, :resume, :fail, :destroy ]

  def index
    @tasks = EventResearchTask.recent.includes(:event_weekly_digest).page(params[:page]).per(20)
  end

  def show
    load_task
    load_task_details
  end

  def create
    account_ids = selected_account_ids
    accounts = EventAccount.active.where(id: account_ids)
    raise ArgumentError, "请选择至少一个已启用的活动" if accounts.empty?

    source = if params[:select_all] == "true"
      :manual_all
    elsif accounts.one?
      :manual_single
    else
      :manual_selected
    end
    task = EventResearchTask.create_for!(accounts, source: source, refresh_cache: params[:refresh_cache] == "1")
    EventResearchTaskJob.perform_later(task.id)

    redirect_to event_research_task_path(task), flash: { success: "已为 #{task.total} 个活动创建研究任务" }
  rescue ArgumentError => e
    redirect_back fallback_location: accounts_path(scope: "event"), flash: { error: e.message }
  end

  def pause
    load_task
    @task.pause!
    redirect_to event_research_task_path(@task), flash: { success: "研究任务已暂停；已开始的活动会安全结束" }
  end

  def resume
    load_task
    @task.resume!
    redirect_to event_research_task_path(@task), flash: { success: "研究任务已恢复" }
  end

  def fail
    load_task
    @task.mark_failed!("手动标记为失败")
    EventWeeklyDigestJob.perform_later(@task.id, auto_send: @task.scheduled?)
    redirect_to event_research_task_path(@task), flash: { success: "研究任务已标记为失败，并将生成报告" }
  end

  def logs
    load_task
    @logs = @task.crawl_logs.recent
    @logs = @logs.where(level: params[:level]) if params[:level].present?
    @logs = @logs.where("message LIKE ?", "%#{params[:q]}%") if params[:q].present?
    @logs = @logs.page(params[:page]).per(100)
  end

  def poll
    load_task
    load_task_details
  end

  def destroy
    load_task
    unless @task.completed? || @task.failed?
      redirect_to event_research_task_path(@task), flash: { error: "只能删除已完成或已失败的任务" } and return
    end

    @task.destroy!
    redirect_to event_research_tasks_path, flash: { success: "研究任务已删除" }
  end

  private

  def load_task
    @task = EventResearchTask.find(params[:id])
  end

  def load_task_details
    @items = @task.event_research_task_accounts.includes(:account, :event_research_run).order(:id)
    @api_usage = @task.api_usage(@items)
    @recent_logs = @task.crawl_logs.recent.where.not(level: :debug).limit(50)
  end

  def selected_account_ids
    if params[:select_all] == "true"
      scope = EventAccount.all
      scope = scope.ransack(search_params).result if params[:q].present?
      scope.pluck(:id)
    else
      Array(params[:account_ids]).map(&:to_i).reject(&:zero?)
    end
  end

  def search_params
    value = params.fetch(:q, {})
    value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value.to_h
  end
end
