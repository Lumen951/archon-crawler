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
    @twitter_ct0 = Option.get('twitter_ct0')
    @twitter_auth_token = Option.get('twitter_auth_token')
    @twitter_proxy = Option.get('twitter_proxy')
    @wechat_key_check = Rails.cache.read('api_key_check:wechat')
    @rednote_key_check = Rails.cache.read('api_key_check:rednote')
    @twitter_key_check = Rails.cache.read('api_key_check:twitter')
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

    if params[:twitter_ct0].present?
      Option.set('twitter_ct0', params[:twitter_ct0])
      flash[:success] = "Twitter ct0 cookie 更新成功"
    end

    if params[:twitter_auth_token].present?
      Option.set('twitter_auth_token', params[:twitter_auth_token])
      flash[:success] = "Twitter auth_token cookie 更新成功"
    end

    if params.key?(:twitter_proxy)
      if params[:twitter_proxy].present?
        Option.set('twitter_proxy', params[:twitter_proxy])
        flash[:success] = "Twitter 代理更新成功"
      else
        Option.set('twitter_proxy', nil)
        flash[:success] = "Twitter 代理已清除"
      end
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

  def validate_wechat_key
    valid = WechatApiClient.validate_key
    result = { valid: valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:wechat', result, expires_in: 2.hours)
    flash[:success] = valid ? "✓ 微信 API 密钥有效" : "✗ 微信 API 密钥无效或已过期"
    redirect_to admin_settings_path
  rescue => e
    Rails.logger.error("WeChat API key validation error: #{e.message}")
    flash[:error] = "验证失败：#{e.message[0..200]}"
    redirect_to admin_settings_path
  end

  def validate_rednote_key
    valid = RednoteApiClient.validate_key
    result = { valid: valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:rednote', result, expires_in: 2.hours)
    flash[:success] = valid ? "✓ 小红书 API 密钥有效" : "✗ 小红书 API 密钥无效"
    redirect_to admin_settings_path
  rescue => e
    Rails.logger.error("RedNote API key validation error: #{e.message}")
    flash[:error] = "验证失败：#{e.message[0..200]}"
    redirect_to admin_settings_path
  end

  def validate_twitter_key
    valid = TwitterApiClient.validate_key
    result = { valid: valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:twitter', result, expires_in: 2.hours)
    flash[:success] = valid ? "✓ Twitter cookies 有效" : "✗ Twitter cookies 无效或已过期"
    redirect_to admin_settings_path
  rescue => e
    Rails.logger.error("Twitter API key validation error: #{e.message}")
    flash[:error] = "验证失败：#{e.message[0..200]}"
    redirect_to admin_settings_path
  end
end
