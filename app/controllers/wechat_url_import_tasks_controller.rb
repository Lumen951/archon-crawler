class WechatUrlImportTasksController < ApplicationController
  def index
    @tasks = WechatUrlImportTask.recent.page(params[:page]).per(20)
  end

  def show
    @task = WechatUrlImportTask.find(params[:id])
  end

  def poll
    @task = WechatUrlImportTask.find(params[:id])
  end

  def destroy
    @task = WechatUrlImportTask.find(params[:id])

    unless @task.completed? || @task.failed?
      flash[:error] = "只能删除已完成或已失败的任务"
      redirect_to wechat_url_import_task_path(@task) and return
    end

    @task.destroy!
    flash[:success] = "微信文章链接导入任务已删除"
    redirect_to wechat_url_import_tasks_path
  end
end
