class DashboardController < ApplicationController
  def index
    @total_accounts = Account.count
    @active_accounts = Account.active.count
    @total_articles = Article.count
    @pending_tasks = CrawlTask.active.count
    @due_accounts = Account.due_for_crawl.count
    @recent_tasks = CrawlTask.recent.limit(10)

    # Followed-tag digest stats (no article list — the articles page covers browsing)
    followed_tag_ids = current_user&.followed_tags&.pluck(:id) || []
    if followed_tag_ids.any?
      @followed_tags_count = followed_tag_ids.size
      @followed_accounts_count = Account.joins(:tag_accounts).where(tag_accounts: { tag_id: followed_tag_ids }).distinct.count
      @followed_articles_today = Article.joins(account: :tag_accounts)
        .where(tag_accounts: { tag_id: followed_tag_ids })
        .where("articles.created_at >= ?", Time.current.beginning_of_day)
        .count
    else
      @followed_tags_count = 0
      @followed_accounts_count = 0
      @followed_articles_today = 0
    end
  end
end
