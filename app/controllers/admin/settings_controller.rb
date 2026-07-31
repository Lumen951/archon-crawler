class Admin::SettingsController < Admin::BaseController
  def show
    @api_key_value = Option.api_key
    @api_key_expires_at = Option.get('wechat_api_key_expires_at')
    @wechat_api_provider = Option.wechat_api_provider
    @dajiala_api_key = Option.dajiala_api_key
    @rednote_api_key = Option.rednote_api_key
    @default_article_concurrency = Option.default_article_concurrency
    @default_account_concurrency = Option.default_account_concurrency
    @max_crawl_pages = Option.max_crawl_pages
    @verbose_mode = Option[:crawler_verbose_mode]
    @log_retention_days = Option[:crawler_log_retention_days]
    @twitter_ct0 = Option.get('twitter_ct0')
    @twitter_auth_token = Option.get('twitter_auth_token')
    @twitter_proxy = Option.get('twitter_proxy')
    @tikhub_api_key = Option.tikhub_api_key
    @wechat_key_check = Rails.cache.read('api_key_check:wechat')
    @dajiala_key_check = Rails.cache.read('api_key_check:dajiala')
    @rednote_key_check = Rails.cache.read('api_key_check:rednote')
    @twitter_key_check = Rails.cache.read('api_key_check:twitter')
    @tikhub_key_check = Rails.cache.read('api_key_check:tikhub')
  end

  def update
    message = nil

    if params[:wechat_api_provider].present?
      Option.wechat_api_provider = params[:wechat_api_provider]
      message = "微信 API 提供商已切换为 #{params[:wechat_api_provider]}"
    end

    if params[:dajiala_api_key].present?
      Option.dajiala_api_key = params[:dajiala_api_key]
      message = "Dajiala API 密钥更新成功"
    end

    if params[:api_key].present?
      expires_at = params[:expires_days].to_i.days.from_now
      Option.api_key = params[:api_key]
      Option.set('wechat_api_key_expires_at', expires_at.iso8601)
      message = "API 密钥更新成功"
    end

    if params[:rednote_api_key].present?
      Option.rednote_api_key = params[:rednote_api_key]
      message = "小红书 API 密钥更新成功"
    end

    if params[:tikhub_api_key].present?
      Option.tikhub_api_key = params[:tikhub_api_key]
      message = "TikHub API 密钥更新成功"
    end

    if params[:twitter_ct0].present?
      Option.set('twitter_ct0', params[:twitter_ct0])
      message = "Twitter ct0 cookie 更新成功"
    end

    if params[:twitter_auth_token].present?
      Option.set('twitter_auth_token', params[:twitter_auth_token])
      message = "Twitter auth_token cookie 更新成功"
    end

    if params.key?(:twitter_proxy)
      if params[:twitter_proxy].present?
        Option.set('twitter_proxy', params[:twitter_proxy])
        message = "Twitter 代理更新成功"
      else
        Option.set('twitter_proxy', nil)
        message = "Twitter 代理已清除"
      end
    end

    if params[:default_article_concurrency].present?
      Option.set('default_article_concurrency', params[:default_article_concurrency])
      message = "默认文章并发数更新成功"
    end

    if params[:default_account_concurrency].present?
      Option.set('default_account_concurrency', params[:default_account_concurrency])
      message = "默认账号并发数更新成功"
    end

    if params[:max_crawl_pages].present?
      Option.set('max_crawl_pages', params[:max_crawl_pages])
      message = "最大抓取页数更新成功"
    end

    if params[:verbose_mode].present?
      Option[:crawler_verbose_mode] = params[:verbose_mode] == '1'
      message = "详细日志模式更新成功"
    end

    if params[:log_retention_days].present?
      Option[:crawler_log_retention_days] = params[:log_retention_days]
      message = "日志保留天数更新成功"
    end

    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message || "设置已更新") }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
    end
  end

  def validate_wechat_key
    valid = WechatApiClient.validate_key
    result = { valid: valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:wechat', result, expires_in: 2.hours)
    message = valid ? "✓ 微信 API 密钥有效" : "✗ 微信 API 密钥无效或已过期"
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: valid ? :success : :error) }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
    end
  rescue => e
    Rails.logger.error("WeChat API key validation error: #{e.message}")
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream("验证失败：#{e.message[0..200]}", type: :error) }
      format.html { flash[:error] = "验证失败：#{e.message[0..200]}"; redirect_to admin_settings_path }
    end
  end

  def validate_dajiala_key
    valid = DajialaApiClient.validate_key
    result = { valid: valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:dajiala', result, expires_in: 2.hours)
    message = valid ? "✓ Dajiala API 密钥有效" : "✗ Dajiala API 密钥无效"
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: valid ? :success : :error) }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
    end
  rescue => e
    Rails.logger.error("Dajiala API key validation error: #{e.message}")
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream("验证失败：#{e.message[0..200]}", type: :error) }
      format.html { flash[:error] = "验证失败：#{e.message[0..200]}"; redirect_to admin_settings_path }
    end
  end

  def validate_rednote_key
    valid = RednoteApiClient.validate_key
    result = { valid: valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:rednote', result, expires_in: 2.hours)
    message = valid ? "✓ 小红书 API 密钥有效" : "✗ 小红书 API 密钥无效"
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: valid ? :success : :error) }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
    end
  rescue => e
    Rails.logger.error("RedNote API key validation error: #{e.message}")
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream("验证失败：#{e.message[0..200]}", type: :error) }
      format.html { flash[:error] = "验证失败：#{e.message[0..200]}"; redirect_to admin_settings_path }
    end
  end

  def validate_twitter_key
    valid = TwitterApiClient.validate_key
    result = { valid: valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:twitter', result, expires_in: 2.hours)
    message = valid ? "✓ Twitter cookies 有效" : "✗ Twitter cookies 无效或已过期"
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: valid ? :success : :error) }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
    end
  rescue => e
    Rails.logger.error("Twitter API key validation error: #{e.message}")
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream("验证失败：#{e.message[0..200]}", type: :error) }
      format.html { flash[:error] = "验证失败：#{e.message[0..200]}"; redirect_to admin_settings_path }
    end
  end

  def validate_tikhub_key
    valid = TikHubApiClient.validate_key
    result = { valid: valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:tikhub', result, expires_in: 2.hours)
    message = valid ? "✓ TikHub API 密钥有效" : "✗ TikHub API 密钥无效"
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: valid ? :success : :error) }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
    end
  rescue => e
    Rails.logger.error("TikHub API key validation error: #{e.message}")
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream("验证失败：#{e.message[0..200]}", type: :error) }
      format.html { flash[:error] = "验证失败：#{e.message[0..200]}"; redirect_to admin_settings_path }
    end
  end
end
