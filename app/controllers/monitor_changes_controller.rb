class MonitorChangesController < ApplicationController
  def index
    @changes = MonitorChange.includes(:account, :monitor_page).recent
    @changes = @changes.where(account_id: params[:account_id]) if params[:account_id].present?
    @changes = @changes.important if params[:important].present?
    @changes = @changes.unnotified if params[:unnotified].present?
    @changes = @changes.page(params[:page]).per(30)
    @account = Account.find_by(id: params[:account_id])
  end

  def show
    @change = MonitorChange.includes(:account, :monitor_page, :monitor_page_version).find(params[:id])
    @previous_version = MonitorPageVersion.find_by(id: @change.previous_version_id)
    @current_version = @change.monitor_page_version
    if @previous_version && @current_version
      @diff = WebsiteCrawler::Analyzer.new.diff(@previous_version.content, @current_version.content)
    end
  end
end
