class Admin::SettingsController < Admin::BaseController
  def show
    @api_key_value = Option.api_key
    @api_key_expires_at = Option.get('wechat_api_key_expires_at')
    @rednote_api_key = Option.rednote_api_key
    @default_article_concurrency = Option.default_article_concurrency
    @default_account_concurrency = Option.default_account_concurrency
    @max_crawl_pages = Option.max_crawl_pages
    @verbose_mode = Option[:crawler_verbose_mode]
    @log_retention_days = Option[:crawler_log_retention_days]
  end

  def update
    if params[:api_key].present?
      expires_at = params[:expires_days].to_i.days.from_now
      Option.api_key = params[:api_key]
      Option.set('wechat_api_key_expires_at', expires_at.iso8601)
      flash[:success] = "API 密钥更新成功"
    end

    if params[:rednote_api_key].present?
      Option.rednote_api_key = params[:rednote_api_key]
      flash[:success] = "小红书 API 密钥更新成功"
    end

    if params[:default_article_concurrency].present?
      Option.set('default_article_concurrency', params[:default_article_concurrency])
      flash[:success] = "默认文章并发数更新成功"
    end

    if params[:default_account_concurrency].present?
      Option.set('default_account_concurrency', params[:default_account_concurrency])
      flash[:success] = "默认账号并发数更新成功"
    end

    if params[:max_crawl_pages].present?
      Option.set('max_crawl_pages', params[:max_crawl_pages])
      flash[:success] = "最大抓取页数更新成功"
    end

    if params[:verbose_mode].present?
      Option[:crawler_verbose_mode] = params[:verbose_mode] == '1'
      flash[:success] = "详细日志模式更新成功"
    end

    if params[:log_retention_days].present?
      Option[:crawler_log_retention_days] = params[:log_retention_days]
      flash[:success] = "日志保留天数更新成功"
    end

    redirect_to admin_settings_path
  end
end
