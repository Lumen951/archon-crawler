class Admin::AnalyticsController < Admin::BaseController
  def show
    # Single source of truth: the disjoint activity tiers. The distribution
    # chart and the platform table's "总计" row both derive from these buckets.
    @activity_distribution = {
      active:    Account.by_activity_level("active").count,
      slow:      Account.by_activity_level("slow").count,
      dormant:   Account.by_activity_level("dormant").count,
      dead:      Account.by_activity_level("dead").count,
      never:     Account.by_activity_level("never").count,
      uncrawled: Account.by_activity_level("uncrawled").count,
    }
    @summary = {
      total: Account.count,
      avg_score: Account.average(:activity_score)&.round(1) || 0,
    }.merge(@activity_distribution)

    @platform_stats = Account.platform_activity_stats
    @top_publishers_7d = Account.active
      .where("articles_last_7_days > 0")
      .order(articles_last_7_days: :desc)
      .limit(20)
    @top_publishers_30d = Account.active
      .where("articles_last_30_days > 0")
      .order(articles_last_30_days: :desc)
      .limit(20)
    @dormant_attention = Account.needs_attention
      .order(:last_published_at)
      .limit(30)
    @new_accounts = {
      yesterday: Account.new_accounts_by_platform(Date.yesterday.beginning_of_day),
      last_week: Account.new_accounts_by_platform(7.days.ago),
      last_month: Account.new_accounts_by_platform(30.days.ago),
    }
    @crawl_progress = Account.activity_crawl_progress
    @daily_articles = Article
      .where("published_at >= ?", 30.days.ago)
      .group("DATE(published_at)")
      .order("DATE(published_at)")
      .count
  end

  def bulk_disable_dormant
    days = (params[:days] || 90).to_i
    cutoff = days.days.ago
    scope = Account.active.where.not(last_crawled_at: nil).where("total_articles > 0").where("last_published_at < ? OR last_published_at IS NULL", cutoff)
    count = scope.update_all(status: :inactive, updated_at: Time.current)
    flash[:success] = "已停用 #{count} 个长期未更新的帐号（#{days}天以上无发布）"
    redirect_to admin_analytics_path
  end
end
