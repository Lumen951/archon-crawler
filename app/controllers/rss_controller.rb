class RssController < ApplicationController
  allow_unauthenticated_access

  def index
    @articles = Article.includes(:account).recent

    case params[:period]
    when 'today'
      @articles = @articles.today
      @period_label = "今天"
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
end
