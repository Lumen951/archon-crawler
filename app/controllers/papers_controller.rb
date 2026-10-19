class PapersController < ApplicationController
  def index
    @papers = Paper.includes(:sources, :authorships, :authors).order(published_at: :desc, id: :desc).page(params[:page]).per(20)
  end

  def import
    @task = PaperImportTask.new
  end

  def create_import
    urls = params.dig(:paper_import, :urls).to_s.lines.map(&:strip).reject(&:blank?).uniq
    if urls.empty? || urls.length > 20 || urls.any? { |url| url.bytesize > 2048 }
      @task = PaperImportTask.new
      flash.now[:error] = "每次请输入 1–20 个论文链接，每个链接不超过 2048 字节"
      return render :import, status: :unprocessable_entity
    end

    PaperImportTask.transaction do
      @task = current_user.paper_import_tasks.create!(total_count: urls.length)
      @task.items.create!(urls.map { |url| { url: url } })
    end
    begin
      queued = PaperImportJob.perform_later(@task.id)
      raise ActiveJob::EnqueueError, "Enqueue aborted" unless queued
    rescue StandardError => e
      Rails.logger.warn("Paper import enqueue failed: #{e.class}")
      @task.update!(status: :failed, completed_at: Time.current, error_message: "任务未能入队，请重新提交链接")
      return redirect_to paper_import_task_path(@task), flash: { error: "任务未能入队，请重新提交链接" }
    end
    redirect_to paper_import_task_path(@task), flash: { success: "已提交 #{urls.length} 个论文链接" }
  end

  def show
    @paper = Paper.includes(:sources, authorships: :paper_author).find(params[:id])
  end
end
