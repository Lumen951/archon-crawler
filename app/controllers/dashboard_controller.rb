class DashboardController < ApplicationController
  def index
    @total_accounts = Account.count
    @active_accounts = Account.active.count
    @total_articles = Article.count
    @pending_tasks = CrawlTask.active.count
    @recent_tasks = CrawlTask.recent.limit(10)
    @api_key_expires_soon = Option.api_key_expires_soon?
    @wechat_key_check = Rails.cache.read('api_key_check:wechat')
    @rednote_key_check = Rails.cache.read('api_key_check:rednote')
  end
end
