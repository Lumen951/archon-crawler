class MonitorPagesController < ApplicationController
  def show
    @page = MonitorPage.includes(:account, :current_version).find(params[:id])
    @versions = @page.monitor_page_versions.recent
    @changes = @page.monitor_changes.recent
  end
end
