# 活动研究控制台。活动研究账号（EventAccount）不进文章账号的 show 页，
# 这里是它唯一的工作界面：查看配置、启动/重启调研、跟踪运行日志、查看与
# 下载数据 JSON。
#
# 调研的执行在 EventResearchJob（独立于抓取管线）；本控制器只做轻量的
# 任务编排与结果展示，不做任何网络调用。
class EventAccountsController < ApplicationController
  before_action :require_admin, only: [ :start_research, :fail_run ]

  def show
    @account = EventAccount.find(params[:id])
    load_runs
  end

  # 启动一轮新调研（可勾选忽略缓存）。前置条件在控制器先检查一遍给出友好提示，
  # EventResearchJob 里还会再兜底一次。
  def start_research
    @account = EventAccount.find(params[:id])

    unless LlmClient.configured?
      redirect_to event_account_path(@account), flash: { error: "未配置 LLM 密钥（openai_api_key），请先在管理设置中配置" } and return
    end
    unless serper_api_key.present?
      redirect_to event_account_path(@account), flash: { error: "未配置 Serper API 密钥，请先在管理设置中配置 serper_api_key" } and return
    end

    run = EventResearchRun.start_for!(@account, refresh_cache: params[:refresh_cache] == "1")
    flash[:success] = "已启动调研（run##{run.id}）#{run.refresh_cache? ? "，本次忽略缓存" : ""}"
    redirect_to event_account_path(@account, run_id: run.id)
  rescue EventResearchRun::ConcurrentRunError => e
    redirect_to event_account_path(@account), flash: { warning: e.message }
  rescue ActiveRecord::RecordNotFound
    redirect_to accounts_path, flash: { error: "活动研究帐号不存在" }
  end

  # 运行卡死（进程被杀、worker 重启）时的手动出口：把进行中的调研标记为失败，
  # 之后就能重新启动新一轮。
  def fail_run
    @account = EventAccount.find(params[:id])
    run = @account.event_research_runs.find(params[:run_id])

    unless run.pending? || run.running?
      redirect_to event_account_path(@account, run_id: run.id), flash: { error: "只能标记进行中的调研" } and return
    end

    run.mark_failed!("手动标记为失败")
    redirect_to event_account_path(@account, run_id: run.id), flash: { success: "已标记为失败，可以重新启动调研" }
  rescue ActiveRecord::RecordNotFound
    redirect_to accounts_path, flash: { error: "活动研究帐号不存在" }
  end

  def logs
    @account = EventAccount.find(params[:id])
    load_runs
    @level = params[:level].presence
    @q = params[:q].presence

    scope = @run ? @run.crawl_logs.recent : CrawlLog.none
    scope = scope.by_level(@level) if @level
    scope = scope.where("message LIKE ?", "%#{@q}%") if @q
    @logs = scope.page(params[:page]).per(100)
  end

  # task-poller 轮询端点：返回替换研究主体的 Turbo Stream
  def poll
    @account = EventAccount.find(params[:id])
    load_runs
  end

  def download
    @account = EventAccount.find(params[:id])
    run = @account.event_research_runs.find(params[:run_id])

    send_data(
      JSON.pretty_generate(run.result || {}, ensure_ascii: false),
      filename: "event-research-#{run.id}-#{EventResearch.slug(@account.nickname)}.json",
      type: "application/json"
    )
  rescue ActiveRecord::RecordNotFound
    redirect_to event_account_path(@account), flash: { error: "调研记录不存在" }
  end

  private

  def load_runs
    @runs = @account.event_research_runs.recent.limit(20)
    @active_run = @account.event_research_runs.active.recent.first
    @run = selected_run
    @recent_logs = @run ? @run.crawl_logs.recent.where.not(level: :debug).limit(50) : CrawlLog.none
  end

  # 优先 URL 指定的 run（校验归属），否则进行中的那轮，否则最近一轮
  def selected_run
    if params[:run_id].present?
      run = @account.event_research_runs.find_by(id: params[:run_id])
      return run if run
    end

    @active_run || @account.event_research_runs.recent.first
  end

  def serper_api_key
    ENV["SERPER_API_KEY"].presence || Option.serper_api_key
  end
end
