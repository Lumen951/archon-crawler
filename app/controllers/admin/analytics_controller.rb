class Admin::AnalyticsController < Admin::BaseController
  def show
    @summary = build_summary
    @platform_stats = Account.platform_activity_stats
    @activity_distribution = {
      very_active: Account.by_activity_level("very_active").count,
      active:      Account.by_activity_level("active").count,
      slow:        Account.by_activity_level("slow").count,
      dormant:     Account.by_activity_level("dormant").count,
      dead:        Account.by_activity_level("dead").count,
      uncrawled:   Account.by_activity_level("uncrawled").count,
    }
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

  private

  def build_summary
    {
      total: Account.count,
      active: Account.active.count,
      published_7d: Account.where("last_published_at >= ?", 7.days.ago).count,
      published_30d: Account.where("last_published_at >= ?", 30.days.ago).count,
      dormant_90d: Account.active.where.not(last_crawled_at: nil).where("total_articles > 0").where("last_published_at < ? OR last_published_at IS NULL", 90.days.ago).count,
      never_published: Account.where(total_articles: 0).where.not(last_crawled_at: nil).count,
      uncrawled: Account.where(last_crawled_at: nil).count,
      avg_score: Account.average(:activity_score)&.round(1) || 0,
    }
  end
end
