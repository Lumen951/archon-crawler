class PaperImportTasksController < ApplicationController
  def show
    @task = current_user.paper_import_tasks.includes(items: :paper).find(params[:id])
  end

  def poll
    @task = current_user.paper_import_tasks.includes(items: :paper).find(params[:id])
  end
end
