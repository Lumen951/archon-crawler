class DailyReportsController < ApplicationController
  def index
    @reports = DailyReport.recent.limit(60)
  end

  def show
    @report = DailyReport.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to daily_reports_path, flash: { error: "日报不存在" }
  end
end
