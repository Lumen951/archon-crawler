class MonitorPageVersionsController < ApplicationController
  def show
    @version = MonitorPageVersion.includes(:monitor_page).find(params[:id])
    @page = @version.monitor_page
    @previous = @page.monitor_page_versions.where("created_at < ?", @version.created_at).recent.first
    @diff = @previous ? WebsiteCrawler::Analyzer.new.diff(@previous.content, @version.content) : nil
  end
end
