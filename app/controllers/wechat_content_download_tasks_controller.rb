class WechatContentDownloadTasksController < ApplicationController
  def index
    @tasks = WechatContentDownloadTask.recent
    @tasks = @tasks.where(status: params[:status]) if params[:status].present?
    @tasks = @tasks.page(params[:page]).per(20)
    @missing_count = Article.wechat_missing_content.count
  end

  def show
    @task = WechatContentDownloadTask.find(params[:id])
    @recent_logs = @task.crawl_logs.recent.where.not(level: :debug).limit(50)
  end

  def logs
    @task = WechatContentDownloadTask.find(params[:id])
    @logs = @task.crawl_logs.recent
    @logs = @logs.where(level: params[:level]) if params[:level].present?
    @logs = @logs.where("message LIKE ?", "%#{params[:q]}%") if params[:q].present?
    @logs = @logs.page(params[:page]).per(100)
  end

  def run
    if WechatContentDownloadTask.alive.exists?
      flash[:warning] = "已有正在运行的正文下载任务"
    else
      WechatContentDownloadJob.perform_later
      flash[:success] = "已提交正文下载任务，请稍后刷新查看进度"
    end
    redirect_to wechat_content_download_tasks_path
  end

  def poll
    @task = WechatContentDownloadTask.find(params[:id])
    @recent_logs = @task.crawl_logs.recent.where.not(level: :debug).limit(50)
  end

  def destroy
    @task = WechatContentDownloadTask.find(params[:id])

    unless @task.completed? || @task.failed? || @task.stale?
      flash[:error] = "只能删除已完成、失败或已过期的任务"
      redirect_to wechat_content_download_task_path(@task) and return
    end

    @task.destroy
    flash[:success] = "正文下载任务已删除"
    redirect_to wechat_content_download_tasks_path
  end
end
