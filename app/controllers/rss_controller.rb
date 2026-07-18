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
      @articles = Article.includes(:account).recent.limit(100)
    end

    @period_label = "个人订阅"

    respond_to do |format|
      format.rss { render :by_user, layout: false }
      format.xml { render template: 'rss/by_user', layout: false, formats: [:rss] }
    end
  end
end
