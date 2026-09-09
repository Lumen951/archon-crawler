class Admin::SettingsController < Admin::BaseController
  def show
    @wechat_api_provider = Option.wechat_api_provider
    @dajiala_api_key = Option.dajiala_api_key
    @rednote_api_key = Option.rednote_api_key
    @default_article_concurrency = Option.default_article_concurrency
    @default_account_concurrency = Option.default_account_concurrency
    @max_crawl_pages = Option.max_crawl_pages
    @daily_crawl_budget_wechat = Option.daily_crawl_budget_for('wechat')
    @daily_crawl_budget_rednote = Option.daily_crawl_budget_for('rednote')
    @daily_crawl_budget_twitter = Option.daily_crawl_budget_for('twitter')
    @daily_crawl_budget_website = Option.daily_crawl_budget_for('website')
    @verbose_mode = Option[:crawler_verbose_mode]
    @log_retention_days = Option[:crawler_log_retention_days]
    @twitter_ct0 = Option.get('twitter_ct0')
    @twitter_auth_token = Option.get('twitter_auth_token')
    @twitter_proxy = Option.get('twitter_proxy')
    @tikhub_api_key = Option.tikhub_api_key
    @dajiala_key_check = Rails.cache.read('api_key_check:dajiala')
    @rednote_key_check = Rails.cache.read('api_key_check:rednote')
    @twitter_key_check = Rails.cache.read('api_key_check:twitter')
    @tikhub_key_check = Rails.cache.read('api_key_check:tikhub')
    @crawl_wechat_enabled = Option.crawl_wechat_enabled?
    @crawl_rednote_enabled = Option.crawl_rednote_enabled?
    @crawl_twitter_enabled = Option.crawl_twitter_enabled?
    @crawl_website_enabled = Option.crawl_website_enabled?
    @profile_ext_credentials = Option.profile_ext_credentials
    @profile_ext_expired = Option.profile_ext_credentials_expired?
    @profile_ext_updated_at = Option.profile_ext_credentials_updated_at
    @profile_ext_age_minutes = Option.profile_ext_credentials_age_minutes
    @profile_ext_account_bizs = ProfileExtApiClient.all_account_bizs rescue []
    # MP Native
    @wechat_mp_cookie = Option.wechat_mp_cookie
    @wechat_mp_token = Option.wechat_mp_token
    @wechat_mp_session_valid = Option.wechat_mp_session_valid?
    @wechat_mp_login_state = Option.wechat_mp_login_state
    @wechat_mp_expires_at = Option.wechat_mp_expires_at
    @wechat_mp_account_info = Option.wechat_mp_account_info
    @mp_native_key_check = Rails.cache.read('api_key_check:mp_native')
    # WeRead
    @weread_accounts = Option.weread_accounts
    @weread_has_valid_accounts = Option.weread_accounts_valid?
    @weread_blocked_accounts = Option.weread_blocked_accounts
    @weread_today_blocked = (@weread_blocked_accounts[WereadApiClient.today_shanghai] || [])
    @weread_key_check = Rails.cache.read('api_key_check:weread')
    # WeRead Native (直连扫码登录)
    @weread_native_session_valid = Option.weread_native_session_valid?
    @weread_native_expires_at = Option.weread_native_expires_at
    @weread_native_account_info = Option.weread_native_account_info
    @weread_native_key_check = Rails.cache.read('api_key_check:weread_native')
    # Feishu
    @feishu_enabled = Option.feishu_enabled?
    @feishu_app_id = Option.feishu_app_id
    @feishu_app_secret = Option.feishu_app_secret
    @feishu_receive_id = Option.feishu_receive_id
    @feishu_receive_id_type = Option.feishu_receive_id_type
    @feishu_encrypt_key = Option.feishu_encrypt_key
    @feishu_login_mode = Option.feishu_login_mode
    @feishu_callback_url = build_feishu_callback_url
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

    if params[:daily_crawl_budget_wechat].present?
      Option.set('daily_crawl_budget_wechat', params[:daily_crawl_budget_wechat])
      message = "每日抓取配额更新成功"
    end

    if params[:daily_crawl_budget_rednote].present?
      Option.set('daily_crawl_budget_rednote', params[:daily_crawl_budget_rednote])
      message = "每日抓取配额更新成功"
    end

    if params[:daily_crawl_budget_twitter].present?
      Option.set('daily_crawl_budget_twitter', params[:daily_crawl_budget_twitter])
      message = "每日抓取配额更新成功"
    end

    if params[:daily_crawl_budget_website].present?
      Option.set('daily_crawl_budget_website', params[:daily_crawl_budget_website])
      message = "每日抓取配额更新成功"
    end

    if params[:verbose_mode].present?
      Option[:crawler_verbose_mode] = params[:verbose_mode] == '1'
      message = "详细日志模式更新成功"
    end

    if params[:log_retention_days].present?
      Option[:crawler_log_retention_days] = params[:log_retention_days]
      message = "日志保留天数更新成功"
    end

    if params.key?(:crawl_wechat_enabled)
      Option.set("crawl_wechat_enabled", params[:crawl_wechat_enabled] == "1")
    end

    if params.key?(:crawl_rednote_enabled)
      Option.set("crawl_rednote_enabled", params[:crawl_rednote_enabled] == "1")
    end

    if params.key?(:crawl_twitter_enabled)
      Option.set("crawl_twitter_enabled", params[:crawl_twitter_enabled] == "1")
    end

    if params.key?(:crawl_website_enabled)
      Option.set("crawl_website_enabled", params[:crawl_website_enabled] == "1")
    end

    if params.key?(:profile_ext_credentials)
      begin
        if params[:profile_ext_credentials].present?
          JSON.parse(params[:profile_ext_credentials]) # validate
          Option.profile_ext_credentials = params[:profile_ext_credentials]
          message = "profile_ext 凭证更新成功"
        else
          Option.set('profile_ext_credentials', nil)
          Option.set('profile_ext_credentials_updated_at', nil)
          message = "profile_ext 凭证已清除"
        end
      rescue JSON::ParserError
        message = "凭证 JSON 格式无效，请检查后重新提交"
      end
    end

    if params.key?(:feishu_enabled)
      Option.set("feishu_enabled", params[:feishu_enabled] == "1")
    end

    # 密钥类字段留空表示保持不变，避免重复提交时被清空
    if params[:feishu_app_id].present?
      Option.feishu_app_id = params[:feishu_app_id].to_s.strip
      message = "飞书推送配置更新成功"
    end

    if params[:feishu_app_secret].present?
      Option.feishu_app_secret = params[:feishu_app_secret].to_s.strip
      message = "飞书推送配置更新成功"
    end

    if params[:feishu_receive_id].present?
      Option.feishu_receive_id = params[:feishu_receive_id].to_s.strip
      message = "飞书推送配置更新成功"
    end

    if params.key?(:feishu_receive_id_type)
      Option.feishu_receive_id_type = params[:feishu_receive_id_type]
      message = "飞书推送配置更新成功"
    end

    if params[:feishu_encrypt_key].present?
      Option.feishu_encrypt_key = params[:feishu_encrypt_key].to_s.strip
      message = "飞书推送配置更新成功"
    end

    if params.key?(:feishu_login_mode)
      Option.feishu_login_mode = params[:feishu_login_mode] == "card" ? "card" : "qr"
      message = "飞书扫码登录推送方式已更新"
    end

    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message || "设置已更新") }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
    end
  end

  def validate_wechat_key
    valid = WechatMpNativeApiClient.validate_key
    result = { valid: valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:wechat', result, expires_in: 2.hours)
    message = valid ? "✓ MP 原生会话有效" : "✗ MP 原生会话无效或已过期，请扫码登录"
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: valid ? :success : :error) }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
    end
  rescue => e
    Rails.logger.error("MP Native session validation error: #{e.message}")
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

  def validate_profile_ext_key
    valid = Option.profile_ext_credentials_valid?
    age = Option.profile_ext_credentials_age_minutes
    message = if valid
                "✓ Profile Ext 凭证有效（#{age} 分钟前更新）"
              elsif Option.profile_ext_credentials.present?
                "✗ Profile Ext 凭证已过期（#{age} 分钟前更新，有效期 25 分钟）"
              else
                "✗ 未配置 Profile Ext 凭证"
              end
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: valid ? :success : :error) }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
    end
  rescue => e
    Rails.logger.error("Profile Ext validation error: #{e.message}")
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream("验证失败：#{e.message[0..200]}", type: :error) }
      format.html { flash[:error] = "验证失败：#{e.message[0..200]}"; redirect_to admin_settings_path }
    end
  end

  # ── 扫码登录（微信读书 / 微信公众号平台共用）──────────
  #
  # 登录进行中的 handle（含微信那边累积的 cookie jar）存在 Rails.cache 里，
  # 用一个随机 token 关联——不放 session：本项目用默认 CookieStore（上限 4KB），
  # 而 cookie jar 可能有好几 KB。缓存模式与 MCP 的 WereadLoginSession 一致。

  QR_LOGIN_CACHE_TTL = 5.minutes

  def qr_login_request
    provider = QrLogin.find(params[:provider])
    result = provider.start

    token = SecureRandom.hex(16)
    Rails.cache.write(qr_login_cache_key(token), { provider: provider.key, handle: result[:handle] },
                      expires_in: QR_LOGIN_CACHE_TTL)

    render json: {
      token: token,
      status: "waiting",
      image_src: provider.image_data_uri(result[:image_bytes], result[:image_mime])
    }
  rescue => e
    Rails.logger.error("[QrLogin] request error (#{params[:provider]}): #{e.message}")
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def qr_login_status
    cache_key = qr_login_cache_key(params[:token])
    state = params[:token].present? ? Rails.cache.read(cache_key) : nil

    unless state
      render json: { status: "expired", message: "二维码会话已过期，请重新获取" }
      return
    end

    provider = QrLogin.find(state[:provider])
    result = provider.poll(state[:handle], timeout: 10, allow_retry: false)

    case result[:status]
    when :success
      identity = provider.save_success!(result[:result])
      Rails.cache.delete(cache_key)
      render json: { status: "success", message: "登录成功：#{identity}" }
    when :expired, :error
      Rails.cache.delete(cache_key)
      render json: { status: result[:status].to_s, message: result[:message] }
    else
      # 轮询可能带回新 cookie，回存后下次轮询才不会丢会话
      Rails.cache.write(cache_key, state.merge(handle: result[:handle]), expires_in: QR_LOGIN_CACHE_TTL)
      render json: { status: result[:status].to_s, message: result[:message] }
    end
  rescue => e
    Rails.logger.error("[QrLogin] status error: #{e.message}")
    render json: { status: "error", message: e.message }
  end

  def wechat_mp_logout
    WechatMpNativeApiClient.logout
    message = "已退出微信公众号平台登录"
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: :success) }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
      format.json { render json: { status: "logged_out" } }
    end
  rescue => e
    Rails.logger.error("[MP Native] logout error: #{e.message}")
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream("登出失败：#{e.message[0..200]}", type: :error) }
      format.html { flash[:error] = "登出失败：#{e.message[0..200]}"; redirect_to admin_settings_path }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def validate_mp_native_key
    valid = WechatMpNativeApiClient.validate_session
    result = { valid: valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:mp_native', result, expires_in: 2.hours)
    message = valid ? "✓ MP 原生会话有效" : "✗ MP 原生会话无效或已过期"
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: valid ? :success : :error) }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
      format.json { render json: result }
    end
  rescue => e
    Rails.logger.error("[MP Native] validate error: #{e.message}")
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream("验证失败：#{e.message[0..200]}", type: :error) }
      format.html { flash[:error] = "验证失败：#{e.message[0..200]}"; redirect_to admin_settings_path }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  # ── WeRead 账号管理 ──────────────────────────────────

  def weread_logout
    message = "已取消 WeRead 登录"
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: :success) }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
      format.json { render json: { status: "logged_out" } }
    end
  end

  def validate_weread_key
    valid = WereadApiClient.validate_key
    result = { valid: valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:weread', result, expires_in: 2.hours)
    message = valid ? "✓ WeRead 账号可用" : "✗ WeRead 无可用账号"
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: valid ? :success : :error) }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
      format.json { render json: result }
    end
  rescue => e
    Rails.logger.error("[WeRead] validate error: #{e.message}")
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream("验证失败：#{e.message[0..200]}", type: :error) }
      format.html { flash[:error] = "验证失败：#{e.message[0..200]}"; redirect_to admin_settings_path }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  # ── WeRead Native (直连扫码登录) ──────────────────────

  def weread_native_logout
    Option.weread_native_session_cleared!
    message = "已退出微信读书（直连）登录"
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: :success) }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
      format.json { render json: { status: "logged_out" } }
    end
  end

  def validate_weread_native_key
    valid = WereadNativeApiClient.validate_key
    result = { valid: valid, checked_at: Time.current.iso8601 }
    Rails.cache.write('api_key_check:weread_native', result, expires_in: 2.hours)
    message = valid ? "✓ 微信读书（直连）会话有效" : "✗ 微信读书（直连）会话无效或已过期"
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: valid ? :success : :error) }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
      format.json { render json: result }
    end
  rescue => e
    Rails.logger.error("[WeReadNative] validate error: #{e.message}")
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream("验证失败：#{e.message[0..200]}", type: :error) }
      format.html { flash[:error] = "验证失败：#{e.message[0..200]}"; redirect_to admin_settings_path }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def weread_enable_account
    vid = params[:vid].to_s.strip
    accounts = Option.weread_accounts
    match = accounts.find { |a| a["vid"].to_s == vid }
    if match
      match["status"] = 1
      Option.weread_accounts = accounts
      WereadApiClient.remove_blocked_account(vid)
    end
    redirect_to admin_settings_path, notice: "WeRead 账号已启用"
  end

  def weread_disable_account
    vid = params[:vid].to_s.strip
    accounts = Option.weread_accounts
    match = accounts.find { |a| a["vid"].to_s == vid }
    if match
      match["status"] = 2
      Option.weread_accounts = accounts
    end
    redirect_to admin_settings_path, notice: "WeRead 账号已禁用"
  end

  def weread_remove_account
    vid = params[:vid].to_s.strip
    accounts = Option.weread_accounts
    accounts.reject! { |a| a["vid"].to_s == vid }
    Option.weread_accounts = accounts
    WereadApiClient.remove_blocked_account(vid)
    redirect_to admin_settings_path, notice: "WeRead 账号已移除"
  end

  # ── Feishu 推送 ──────────────────────────────────────

  def test_feishu
    unless FeishuNotifier.enabled?
      message = "飞书推送未启用或配置不完整（app_id / app_secret / receive_id）"
      return respond_to do |format|
        format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: :error) }
        format.html { flash[:error] = message; redirect_to admin_settings_path }
      end
    end

    FeishuNotifier.send_text("✅ 飞书推送配置成功，这是一条测试消息。")
    message = "✓ 已发送测试消息到飞书，请检查"
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream(message, type: :success) }
      format.html { flash[:success] = message; redirect_to admin_settings_path }
    end
  rescue FeishuNotifier::Error => e
    Rails.logger.error("[Feishu] test message error: #{e.message}")
    respond_to do |format|
      format.turbo_stream { render turbo_stream: helpers.toast_stream("测试推送失败：#{e.message[0..200]}", type: :error) }
      format.html { flash[:error] = "测试推送失败：#{e.message[0..200]}"; redirect_to admin_settings_path }
    end
  end

  private

  def qr_login_cache_key(token)
    "qr_login:#{token}"
  end

  # 生成飞书卡片回调地址（与 QrLogin::Base#settings_url 相同的 host 规则）
  def build_feishu_callback_url
    host = ENV["APP_HOST"].presence || "localhost"
    if Rails.env.production?
      "https://#{host}#{Rails.application.routes.url_helpers.feishu_callback_path}"
    else
      "http://#{host}:3000#{Rails.application.routes.url_helpers.feishu_callback_path}"
    end
  end
end
