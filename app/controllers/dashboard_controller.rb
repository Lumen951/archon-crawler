class DashboardController < ApplicationController
  def index
    @total_accounts = Account.count
    @active_accounts = Account.active.count
    @total_articles = Article.count
    @pending_tasks = CrawlTask.active.count
    @recent_tasks = CrawlTask.recent.limit(10)

    # Recent articles filtered by user's followed tags
    followed_tag_ids = current_user&.followed_tags&.pluck(:id) || []
    if followed_tag_ids.any?
      @followed_tags_count = followed_tag_ids.size
      @followed_accounts_count = Account.joins(:tag_accounts).where(tag_accounts: { tag_id: followed_tag_ids }).distinct.count
      @followed_articles_today = Article.joins(account: :tag_accounts)
        .where(tag_accounts: { tag_id: followed_tag_ids })
        .where("articles.created_at >= ?", Time.current.beginning_of_day)
        .count
      article_ids = Article.joins(account: :tag_accounts)
        .where(tag_accounts: { tag_id: followed_tag_ids })
        .distinct.limit(200).pluck(:id)
      @recent_articles = Article.includes(:account)
        .where(id: article_ids).recent.limit(20)
    else
      @followed_tags_count = 0
      @followed_accounts_count = 0
      @followed_articles_today = 0
      @recent_articles = Article.includes(:account).recent.limit(20)
    end
  end
end
