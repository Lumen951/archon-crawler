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

  def download_full_text
    paper = Paper.find(params[:id])
    source = paper.sources.arxiv.find(params[:source_id])
    record = source.prepare_full_text!
    message = if record.nil?
      "缺少论文版本信息，请重新导入论文链接"
    elsif record.enqueue!
      "已提交全文下载，请稍后刷新查看进度"
    else
      "全文已下载、正在处理或暂时不能重试，请查看下载状态"
    end
    redirect_to paper_path(paper), flash: { success: message }
  end

  def read
    @paper = Paper.find(params[:id])
    @full_text = full_text_scope.find(params[:full_text_id])
    unless @full_text.locally_available?
      return redirect_to paper_path(@paper), flash: { error: "本地全文尚未就绪" }
    end

    @article_html = File.read(@full_text.html_path, encoding: "UTF-8")
    response.headers["Content-Security-Policy"] =
      "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'; sandbox allow-same-origin allow-popups"
    response.headers["Cache-Control"] = "private, no-store"
    render layout: false
  end

  def full_text_asset
    record = full_text_scope.find(params[:full_text_id])
    key = params[:resource].to_s
    raise ActiveRecord::RecordNotFound unless record.status_ready? && key.match?(/\A[0-9a-f]{64}\z/)

    resource = record.resources[key]
    path = record.directory.join(key)
    raise ActiveRecord::RecordNotFound unless resource && File.file?(path)

    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Content-Security-Policy"] = "default-src 'none'; sandbox"
    response.headers["Cache-Control"] = "private, no-store"
    send_file path, type: resource.fetch("type"), disposition: "inline"
  end

  private

  def full_text_scope
    PaperFullText.joins(:paper_source).where(paper_sources: { paper_id: params[:id] })
  end
end
