class CrawlTasksController < ApplicationController
  def index
    @crawl_tasks = CrawlTask.recent
    @crawl_tasks = @crawl_tasks.where(status: params[:status]) if params[:status].present?
    @crawl_tasks = @crawl_tasks.page(params[:page]).per(20)
  end

  def show
    @crawl_task = CrawlTask.find(params[:id])
    @recent_logs = @crawl_task.crawl_logs.recent.limit(50)
  end

  def logs
    @crawl_task = CrawlTask.find(params[:id])
    @logs = @crawl_task.crawl_logs.recent.page(params[:page]).per(100)
  end

  def pause
    @crawl_task = CrawlTask.find(params[:id])
    @crawl_task.pause!
    flash[:success] = "抓取任务已暂停"
    redirect_to crawl_tasks_path
  end

  def resume
    @crawl_task = CrawlTask.find(params[:id])

    unless SystemConfig.api_key_valid?
      flash[:error] = "API 密钥已过期。请在设置中更新。"
      redirect_to crawl_tasks_path and return
    end

    @crawl_task.resume!
    flash[:success] = "抓取任务已恢复"
    redirect_to crawl_tasks_path
  end

  def crawl_all
    unless SystemConfig.api_key_valid?
      flash[:error] = "API 密钥已过期。请在设置中更新。"
      redirect_to crawl_tasks_path and return
    end

    if CrawlTask.active.exists?
      flash[:error] = "已有活跃的抓取任务"
      redirect_to crawl_tasks_path and return
    end

    task = CrawlTask.create!(account_ids: nil, status: :pending)
    CrawlJob.perform_later(task.id)
    flash[:success] = "已为所有活跃公众号创建抓取任务"
    redirect_to crawl_tasks_path
  end
end
