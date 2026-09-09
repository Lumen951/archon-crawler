class RssController < ApplicationController
  allow_unauthenticated_access

  def index
    @articles = Article.includes(:account).recent

    case params[:period]
    when 'today'
      @articles = @articles.today
      @period_label = "今天"
    when 'yesterday'
      @articles = @articles.yesterday
      @period_label = "昨天"
    when '7days'
      @articles = @articles.last_7_days
      @period_label = "最近7天"
    when '1month'
      @articles = @articles.last_month
      @period_label = "最近1个月"
    else
      @articles = @articles.last_7_days
      @period_label = "最近7天"
    end

    @articles = @articles.limit(100)

    respond_to do |format|
      format.rss { render layout: false }
      format.xml { render template: 'rss/index', layout: false, formats: [:rss] }
    end
  end

  def show
    @account = Account.find_by!(fakeid: params[:fakeid])
    @articles = @account.rss_items

    respond_to do |format|
      format.rss { render layout: false }
      format.xml { render template: 'rss/show', layout: false, formats: [:rss] }
    end
  end

  def accounts
    @accounts = Account.all.order(created_at: :desc)

    respond_to do |format|
      format.rss { render layout: false }
      format.xml { render template: 'rss/accounts', layout: false, formats: [:rss] }
    end
  end

  def active_accounts
    @accounts = Account.active.order(created_at: :desc)

    respond_to do |format|
      format.rss { render layout: false }
      format.xml { render template: 'rss/active_accounts', layout: false, formats: [:rss] }
    end
  end

  def by_tag
    @tag = Tag.find(params[:tag_id])
    article_ids = Article.joins(account: :tag_accounts)
      .where(tag_accounts: { tag_id: @tag.id })
      .distinct.limit(200).pluck(:id)
    @articles = Article.includes(:account)
      .where(id: article_ids).recent.limit(100)

    @period_label = "标签: #{@tag.name}"

    respond_to do |format|
      format.rss { render :by_tag, layout: false }
      format.xml { render template: 'rss/by_tag', layout: false, formats: [:rss] }
    end
  rescue ActiveRecord::RecordNotFound
    render plain: "Tag not found", status: :not_found
  end

  def monitor_changes
    @changes = monitor_changes_scope
    @feed_title = "官网变更"
    @feed_description = "所有监控官网的最新变更"
    @feed_link = monitor_changes_rss_url

    render_monitor_changes_feed
  end

  def monitor_website_changes
    @website = WebsiteAccount.find(params[:id])
    @changes = monitor_changes_scope.where(account: @website)
    @feed_title = "#{@website.nickname} - 官网变更"
    @feed_description = "#{@website.nickname} 的页面变更"
    @feed_link = monitor_website_changes_rss_url(@website)

    render_monitor_changes_feed
  rescue ActiveRecord::RecordNotFound
    render plain: "Website account not found", status: :not_found
  end

  def monitor_page_changes
    @page = MonitorPage.includes(:account).find(params[:id])
    @changes = monitor_changes_scope.where(monitor_page: @page)
    @feed_title = "#{@page.account.nickname} - #{@page.display_title}"
    @feed_description = "#{@page.display_title} 的页面变更"
    @feed_link = monitor_page_changes_rss_url(@page)

    render_monitor_changes_feed
  rescue ActiveRecord::RecordNotFound
    render plain: "Monitor page not found", status: :not_found
  end

  # Pages feed: one item per monitored page (not per change) — pages move back
  # to the top of the feed whenever their content changes. Complements the
  # changes feeds, which emit one item per detected diff.
  def monitor_pages
    @pages = monitor_pages_scope
    @feed_title = "官网监控页面"
    @feed_description = "所有监控官网的页面，按最近变化排序"
    @feed_link = monitor_pages_rss_url

    render_monitor_pages_feed
  end

  def monitor_website_pages
    @website = WebsiteAccount.find(params[:id])
    @pages = monitor_pages_scope.where(account: @website)
    @feed_title = "#{@website.nickname} - 官网监控页面"
    @feed_description = "#{@website.nickname} 的监控页面"
    @feed_link = monitor_website_pages_rss_url(@website)

    render_monitor_pages_feed
  rescue ActiveRecord::RecordNotFound
    render plain: "Website account not found", status: :not_found
  end

  def by_user
    api_key = ApiKey.find_by(token: params[:token], active: true)
    unless api_key
      render plain: "Unauthorized", status: :unauthorized
      return
    end

    user = api_key.user
    followed_tag_ids = user.followed_tags.pluck(:id)

    if followed_tag_ids.any?
      article_ids = Article.joins(account: :tag_accounts)
        .where(tag_accounts: { tag_id: followed_tag_ids })
        .distinct.limit(200).pluck(:id)
      @articles = Article.includes(:account)
        .where(id: article_ids).recent.limit(100)
    else
      @articles = []
    end

    @period_label = "个人订阅"

    respond_to do |format|
      format.rss { render :by_user, layout: false }
      format.xml { render template: 'rss/by_user', layout: false, formats: [:rss] }
    end
  end

  private

  def render_monitor_changes_feed
    respond_to do |format|
      format.rss { render :monitor_changes, layout: false }
      format.xml { render template: "rss/monitor_changes", layout: false, formats: [:rss] }
    end
  end

  def render_monitor_pages_feed
    respond_to do |format|
      format.rss { render :monitor_pages, layout: false }
      format.xml { render template: "rss/monitor_pages", layout: false, formats: [:rss] }
    end
  end

  def monitor_pages_scope
    scope = MonitorPage.includes(:account, :current_version).active.recently_updated

    scope = scope.where(account_id: params[:account_id]) if params[:account_id].present?
    scope = scope.where(page_type: params[:page_type]) if params[:page_type].present?

    scope.limit(100)
  end

  def monitor_changes_scope
    scope = MonitorChange.includes(:account, :monitor_page)
      .order(created_at: :desc, id: :desc)

    scope = scope.important if params[:important].present?
    scope = scope.unnotified if params[:unnotified].present?
    scope = scope.where(account_id: params[:account_id]) if params[:account_id].present?
    scope = scope.where(monitor_page_id: params[:page_id]) if params[:page_id].present?
    scope = scope.where(change_type: params[:change_type]) if params[:change_type].present?
    scope = scope.where("importance >= ?", params[:importance].to_i) if params[:importance].present?
    scope = scope.where("relevance >= ?", params[:relevance].to_i) if params[:relevance].present?
    scope = apply_monitor_period(scope)

    scope.limit(100)
  end

  def apply_monitor_period(scope)
    case params[:period]
    when "today"
      scope.where("monitor_changes.created_at >= ?", Time.current.beginning_of_day)
    when "yesterday"
      scope.where(created_at: Time.current.beginning_of_day - 1.day...Time.current.beginning_of_day)
    when "7days", nil, ""
      scope.where("monitor_changes.created_at >= ?", 7.days.ago)
    when "1month"
      scope.where("monitor_changes.created_at >= ?", 1.month.ago)
    else
      scope
    end
  end
end
