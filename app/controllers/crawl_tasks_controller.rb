class CrawlTasksController < ApplicationController
  def index
    @crawl_tasks = CrawlTask.recent
    @crawl_tasks = @crawl_tasks.where(status: params[:status]) if params[:status].present?
    @crawl_tasks = @crawl_tasks.page(params[:page]).per(20)
  end

  def show
    @crawl_task = CrawlTask.find(params[:id])
    @recent_logs = @crawl_task.crawl_logs.recent.where.not(level: :debug).limit(50)
  end

  def logs
    @crawl_task = CrawlTask.find(params[:id])
    @logs = @crawl_task.crawl_logs.recent
    @logs = @logs.where(level: params[:level]) if params[:level].present?
    @logs = @logs.where("message LIKE ?", "%#{params[:q]}%") if params[:q].present?
    @logs = @logs.page(params[:page]).per(100)
  end

  def pause
    @crawl_task = CrawlTask.find(params[:id])
    @crawl_task.pause!
    flash[:success] = "抓取任务已暂停"
    redirect_to crawl_tasks_path
  end

  def resume
    @crawl_task = CrawlTask.find(params[:id])

    # accounts = @crawl_task.resolved_accounts
    # has_wechat  = accounts.where(type: "WechatAccount").exists?
    # has_rednote = accounts.where(type: "RednoteAccount").exists?

    # if has_wechat && !Option.api_key_valid?
    #   flash[:error] = "微信 API 密鑰已过期。请在设置中更新。"
    #   redirect_to crawl_tasks_path and return
    # end

    # if has_rednote && !Option.rednote_api_key_valid?
    #   flash[:error] = "小红书 API 密鑰未配置。请在设置中添加 rednote_api_key。"
    #   redirect_to crawl_tasks_path and return
    # end

    # 如果任务正在运行，先暂停它，让正在运行的 crawler 停止
    if @crawl_task.running?
      @crawl_task.pause!
      # 等待一小段时间让正在运行的 crawler 检测到暂停状态并停止
      sleep 1
    end

    @crawl_task.resume!
    flash[:success] = @crawl_task.failed_account_count > 0 ? "正在重试失败的帐号" : "抓取任务已恢复"
    redirect_to crawl_task_path(@crawl_task)
  end

  def fail
    @crawl_task = CrawlTask.find(params[:id])
    @crawl_task.mark_failed!("手动标记失败")
    flash[:success] = "抓取任务已标记为失败"
    redirect_to crawl_tasks_path
  end

  def articles
    @crawl_task = CrawlTask.find(params[:id])
    @articles = @crawl_task.articles.recent.page(params[:page]).per(20)
  end

  def poll
    @crawl_task = CrawlTask.find(params[:id])
    @recent_logs = @crawl_task.crawl_logs.recent.where.not(level: :debug).limit(50)
    # Always return the Turbo Stream so the UI gets the final state update.
    # The poller stops itself after rendering a terminal state.
  end

  def destroy
    @crawl_task = CrawlTask.find(params[:id])

    unless @crawl_task.completed? || @crawl_task.failed?
      flash[:error] = "只能删除已完成或已失败的任务"
      redirect_to crawl_task_path(@crawl_task) and return
    end

    @crawl_task.destroy
    flash[:success] = "抓取任务已删除"
    redirect_to crawl_tasks_path
  end

  def crawl_due
    if CrawlTask.active.exists?
      flash[:error] = "已有活跃的抓取任务"
      redirect_to crawl_tasks_path and return
    end

    account_ids = Account.due_for_crawl_ids(limit: Option.daily_crawl_budget)
    if account_ids.empty?
      flash[:warning] = "没有到期的帐号需要抓取"
      redirect_to crawl_tasks_path and return
    end

    task = CrawlTask.create!(account_ids: account_ids, status: :pending)
    CrawlJob.perform_later(task.id)
    flash[:success] = "已为 #{account_ids.size} 个到期帐号创建抓取任务"
    redirect_to crawl_tasks_path
  end
end
