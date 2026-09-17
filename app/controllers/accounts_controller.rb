class AccountsController < ApplicationController
  include QueryPersistenceConcern

  # Maximum length for flash error messages to avoid cookie overflow
  MAX_FLASH_ERROR_LENGTH = 200

  persist_query_for :index

  def index
    q_params = params.fetch(:q, {})
    q_hash = q_params.respond_to?(:to_unsafe_h) ? q_params.to_unsafe_h : q_params.to_h
    @q = Account.ransack(q_hash)
    @accounts = @q.result(distinct: true).includes(:tags).order(activity_score: :desc, last_published_at: :desc).page(params[:page]).per(20)
    @tags = Tag.ordered
    @active_tag_id = params.dig(:q, :with_tag_id).to_s.presence
    @active_tag = @active_tag_id.present? && @active_tag_id != "none" ? Tag.find_by(id: @active_tag_id) : nil
    @total_filtered_count = @accounts.total_count
    @due_for_crawl_count = @q.result.due_for_crawl.count
    @crawl_progress = Account.activity_crawl_progress
  end

  def show
    @account = Account.find(params[:id])
    @articles = @account.articles.recent.page(params[:page]).per(25)
    if @account.website?
      @monitor_pages = @account.monitor_pages.ordered.limit(20)
      @monitor_changes = @account.monitor_changes.recent.limit(10)
    end
  end

  def update
    @account = Account.find(params[:id])

    if @account.update(account_params)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to account_path(@account), flash: { success: "帐号名称已更新" } }
        format.json { render json: { success: true, nickname: @account.nickname } }
      end
    else
      respond_to do |format|
        format.turbo_stream { render turbo_stream: helpers.toast_stream("更新失败：#{@account.errors.full_messages.join(', ')}", type: :error) }
        format.html { redirect_to account_path(@account), flash: { error: "更新失败：#{@account.errors.full_messages.join(', ')}" } }
        format.json { render json: { errors: @account.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  rescue ActiveRecord::RecordNotFound
    respond_to do |format|
      format.html { redirect_to accounts_path, flash: { error: "帐号不存在" } }
      format.json { render json: { error: "帐号不存在" }, status: :not_found }
    end
  end

  def import
    # Show import landing page with links to each platform
  end

  def import_wechat_page
    # Show WeChat import form
  end

  def import_rednote_page
    # Show RedNote import form
  end

  def import_twitter_page
    # Show Twitter import form
  end

  def import_website_page
    # Show website import form
  end

  def import_wechat_search
    keyword = params[:keyword].to_s.strip

    if keyword.blank?
      flash[:error] = "请输入搜索关键词"
      redirect_to import_wechat_page_accounts_path and return
    end

    @keyword = keyword
    @search_accounts = AccountResolver.search_wechat(keyword)

    if @search_accounts.empty?
      flash[:warning] = "未搜索到匹配的帐号"
      redirect_to import_wechat_page_accounts_path and return
    end

    render :import_preview_wechat
  rescue ArgumentError => e
    flash[:error] = truncate_error(e.message)
    redirect_to import_wechat_page_accounts_path
  rescue WechatMpNativeApiClient::LoginRequiredError => e
    flash[:error] = truncate_error("请先在管理设置中扫码登录微信公众号平台，然后再搜索")
    redirect_to import_wechat_page_accounts_path
  rescue WechatMpNativeApiClient::ApiError => e
    flash[:error] = truncate_error("搜索失败：#{e.message}")
    redirect_to import_wechat_page_accounts_path
  rescue StandardError => e
    flash[:error] = truncate_error("搜索失败：#{e.message}")
    redirect_to import_wechat_page_accounts_path
  end

  def import_wechat_file
    result = if params[:json_text].present?
      Accounts::Importer.import_text(params[:json_text])
    elsif params[:json_file].present?
      Accounts::Importer.import_file(params[:json_file])
    else
      flash[:error] = "请提供 JSON 数据或上传文件"
      redirect_to import_wechat_page_accounts_path and return
    end

    if result.errors.any?
      flash[:error] = truncate_error("部分帐号导入失败：#{result.errors.join('; ')}")
    elsif result.imported_count > 0
      flash[:success] = success_message_for(result)
    elsif result.invalid_count > 0
      flash[:warning] = "没有新帐号需要导入（#{result.skipped_count} 个已存在，#{result.invalid_count} 行缺少必填字段）"
    else
      flash[:warning] = "没有新帐号需要导入（#{result.skipped_count} 个已存在）"
    end

    redirect_to accounts_path
  rescue ArgumentError => e
    flash[:error] = truncate_error(e.message)
    redirect_to import_wechat_page_accounts_path
  rescue StandardError => e
    flash[:error] = truncate_error("导入失败：#{e.message}")
    redirect_to import_wechat_page_accounts_path
  end

  def import_wechat_by_url
    urls = params[:article_urls].to_s.split(/\r?\n/).map(&:strip).reject(&:blank?).uniq

    if urls.empty?
      flash[:error] = "请输入至少一个微信公众号文章链接（每行一个）"
      redirect_to import_wechat_page_accounts_path and return
    end

    task = WechatUrlImportTask.transaction do
      import_task = WechatUrlImportTask.create!(total_count: urls.size, status: :pending)
      import_task.items.create!(urls.map { |url| { url: url } })
      import_task
    end

    WechatUrlImportJob.perform_later(task.id)
    flash[:success] = "已创建微信文章链接导入任务，共 #{urls.size} 个链接"
    redirect_to wechat_url_import_task_path(task)
  rescue ActiveRecord::RecordInvalid => e
    flash[:error] = truncate_error("创建导入任务失败：#{e.message}")
    redirect_to import_wechat_page_accounts_path
  rescue StandardError => e
    flash[:error] = truncate_error("提交导入任务失败：#{e.message}")
    redirect_to import_wechat_page_accounts_path
  end

  def import_wechat
    selected_fakeids = Array(params[:selected_fakeids]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    accounts_data = params[:accounts_data] || {}

    if selected_fakeids.empty?
      flash[:error] = "请至少选择一个帐号"
      redirect_to import_wechat_page_accounts_path and return
    end

    rows = selected_fakeids.filter_map do |fakeid|
      data = accounts_data[fakeid] || accounts_data[fakeid.to_sym]
      next unless data.respond_to?(:[])

      {
        fakeid: fakeid,
        nickname: data["nickname"] || data[:nickname],
        round_head_img: data["round_head_img"] || data[:round_head_img],
        total_articles: data["total_articles"] || data[:total_articles] || data["articles"] || data[:articles]
      }
    end

    result = Accounts::Importer.import_search_rows(rows)

    if result.errors.any?
      flash[:error] = truncate_error("部分帐号导入失败：#{result.errors.join('; ')}")
    elsif result.imported_count > 0
      flash[:success] = success_message_for(result)
    else
      flash[:warning] = "没有新帐号需要导入（#{result.skipped_count} 个已存在）"
    end

    redirect_to accounts_path
  rescue ArgumentError => e
    flash[:error] = truncate_error(e.message)
    redirect_to import_wechat_page_accounts_path
  rescue WechatMpNativeApiClient::LoginRequiredError => e
    flash[:error] = truncate_error("请先在管理设置中扫码登录微信公众号平台，然后再导入")
    redirect_to import_wechat_page_accounts_path
  rescue WechatMpNativeApiClient::ApiError => e
    flash[:error] = truncate_error("搜索失败：#{e.message}")
    redirect_to import_wechat_page_accounts_path
  rescue StandardError => e
    flash[:error] = truncate_error("导入失败：#{e.message}")
    redirect_to import_wechat_page_accounts_path
  end

  def import_website
    lines = params[:urls].to_s.split(/\r?\n/).map(&:strip).reject(&:blank?)

    if lines.empty?
      flash[:error] = "请输入至少一个网址（每行一个：名称, 网址 或仅网址）"
      redirect_to import_website_page_accounts_path and return
    end

    result = Website::Importer.import_lines(lines)

    if result.errors.any?
      flash[:warning] = truncate_error("部分网址导入失败：#{result.errors.join('; ')}")
    elsif result.imported_count.positive?
      flash[:success] = success_message_for(result)
    elsif result.skipped_count.positive?
      flash[:warning] = "没有新网站需要导入（#{result.skipped_count} 个已存在）"
    else
      flash[:warning] = "没有新网站需要导入"
    end

    redirect_to accounts_path(q: { type_eq: "WebsiteAccount" })
  end

  def rediscover
    @account = Account.find(params[:id])

    unless @account.website?
      flash[:error] = "只有官网帐号支持重新发现监控页面"
      redirect_to account_path(@account) and return
    end

    crawl_task = nil
    begin
      @account.monitor_pages.destroy_all if @account.crawl_mode == "sitemap"
      crawl_task = @account.crawl!
      flash[:success] = if @account.crawl_mode == "sitemap"
        "已清空 #{@account.nickname} 的监控页面并启动重新发现"
      else
        "已为 #{@account.nickname} 启动列表抓取"
      end
    rescue StandardError => e
      flash[:error] = "启动重新发现失败：#{e.message}"
    end

    if crawl_task
      redirect_to crawl_task_path(crawl_task)
    else
      redirect_to account_path(@account)
    end
  end

  def update_crawl_rule
    @account = Account.find(params[:id])
    require_website_account!(@account)

    rule = WebsiteCrawler::ListingRule.from_json(@account, params[:crawl_rule_json])
    @account.update!(crawl_rule: rule.definition)
    flash[:success] = "官网抓取规则已更新"
    redirect_to account_path(@account)
  rescue ActiveRecord::RecordNotFound
    redirect_to accounts_path, flash: { error: "帐号不存在" }
  rescue WebsiteCrawler::ListingRule::InvalidRule, JSON::ParserError => e
    redirect_to account_path(@account), flash: { error: "抓取规则无效：#{e.message}" }
  end

  def crawl
    @account = Account.find(params[:id])

    begin
      crawl_task = @account.crawl!
      flash[:success] = "已为 #{@account.nickname} 启动抓取"
    rescue StandardError => e
      flash[:error] = "启动抓取失败：#{e.message}"
    end

    redirect_to crawl_task_path(crawl_task)
  end

  def toggle_status
    @account = Account.find(params[:id])
    @account.update!(status: @account.active? ? :inactive : :active)
    flash[:success] = "帐号状态已更新"
    redirect_back fallback_location: accounts_path
  end

  def destroy
    account = Account.find(params[:id])
    name = account.nickname
    account.destroy!
    flash[:success] = "帐号 #{name} 已删除"
    redirect_to accounts_path
  rescue ActiveRecord::RecordNotFound
    flash[:error] = "帐号不存在"
    redirect_to accounts_path
  rescue StandardError => e
    flash[:error] = "删除失败：#{e.message}"
    redirect_back fallback_location: accounts_path
  end

  def bulk_tag
    tag_names = params[:tag_names].to_a.map(&:strip).reject(&:blank?)
    account_ids = resolve_bulk_account_ids

    if tag_names.blank? || account_ids.blank?
      flash[:error] = "请选择帐号并输入标签"
      redirect_back fallback_location: accounts_path and return
    end

    tags = tag_names.map { |name| Tag.find_or_create_by_name(name) }.compact
    added = 0
    account_ids.each do |aid|
      tags.each do |tag|
        TagAccount.find_or_create_by(tag: tag, account_id: aid)
        added += 1
      end
    end
    flash[:success] = "已为 #{account_ids.size} 个帐号添加 #{tags.size} 个标签"
    redirect_back fallback_location: accounts_path
  rescue StandardError => e
    flash[:error] = "操作失败：#{e.message}"
    redirect_back fallback_location: accounts_path
  end

  def bulk_untag
    tag_ids = params[:tag_ids].to_a
    account_ids = resolve_bulk_account_ids

    if tag_ids.blank? || account_ids.blank?
      flash[:error] = "请选择帐号和标签"
      redirect_back fallback_location: accounts_path and return
    end

    removed = TagAccount.where(tag_id: tag_ids, account_id: account_ids).destroy_all.count
    flash[:success] = "已移除 #{removed} 个标签关联"
    redirect_back fallback_location: accounts_path
  rescue StandardError => e
    flash[:error] = "操作失败：#{e.message}"
    redirect_back fallback_location: accounts_path
  end

  def bulk_enable
    account_ids = resolve_bulk_account_ids
    if account_ids.blank?
      flash[:error] = "请选择帐号"
      redirect_back fallback_location: accounts_path and return
    end

    count = Account.where(id: account_ids).update_all(status: :active)
    flash[:success] = "已启用 #{count} 个帐号"
    redirect_back fallback_location: accounts_path
  rescue StandardError => e
    flash[:error] = "操作失败：#{e.message}"
    redirect_back fallback_location: accounts_path
  end

  def bulk_disable
    account_ids = resolve_bulk_account_ids
    if account_ids.blank?
      flash[:error] = "请选择帐号"
      redirect_back fallback_location: accounts_path and return
    end

    count = Account.where(id: account_ids).update_all(status: :inactive)
    flash[:success] = "已停用 #{count} 个帐号"
    redirect_back fallback_location: accounts_path
  rescue StandardError => e
    flash[:error] = "操作失败：#{e.message}"
    redirect_back fallback_location: accounts_path
  end

  def bulk_destroy
    account_ids = resolve_bulk_account_ids
    if account_ids.blank?
      flash[:error] = "请选择帐号"
      redirect_back fallback_location: accounts_path and return
    end

    count = Account.where(id: account_ids).destroy_all.count
    flash[:success] = "已删除 #{count} 个帐号"
    redirect_to accounts_path
  rescue StandardError => e
    flash[:error] = "删除失败：#{e.message}"
    redirect_back fallback_location: accounts_path
  end

  def bulk_crawl
    account_ids = resolve_bulk_account_ids
    if account_ids.blank?
      flash[:error] = "请选择帐号"
      redirect_back fallback_location: accounts_path and return
    end

    accounts = Account.where(id: account_ids).active
    if accounts.empty?
      flash[:error] = "选中的帐号中没有活跃帐号"
      redirect_back fallback_location: accounts_path and return
    end

    crawl_task = CrawlTask.create!(account_ids: accounts.ids, status: :pending)
    CrawlJob.perform_later(crawl_task.id)
    flash[:success] = "已为 #{accounts.size} 个帐号启动抓取"
    redirect_to crawl_task_path(crawl_task)
  rescue StandardError => e
    flash[:error] = "启动抓取失败：#{e.message}"
    redirect_back fallback_location: accounts_path
  end

  def tag_suggestions
    query = params[:q].to_s.strip
    tags = query.blank? ? Tag.ordered.limit(20) : Tag.search(query).ordered.limit(10)
    render json: tags.map { |t| { id: t.id, name: t.name, color: t.color, count: t.tag_accounts_count } }
  end

  def toggle_tag_follow
    tag = Tag.find(params[:tag_id])
    if current_user.followed_tags.exists?(tag.id)
      current_user.user_tags.find_by(tag: tag)&.destroy
      render json: { followed: false }
    else
      current_user.user_tags.create!(tag: tag)
      render json: { followed: true }
    end
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def import_rednote
    result = if params[:rednote_json_text].present?
      Rednote::Importer.import_text(params[:rednote_json_text])
    elsif params[:rednote_json_file].present?
      Rednote::Importer.import_file(params[:rednote_json_file])
    else
      flash[:error] = "请提供 JSON 数据或上传文件"
      redirect_to import_rednote_page_accounts_path and return
    end

    if result.errors.any?
      flash[:error] = truncate_error("部分帐号导入失败：#{result.errors.join('; ')}")
    elsif result.imported_count > 0
      message = "成功导入 #{result.imported_count} 个小红书帐号（#{result.skipped_count} 个重复已跳过）"
      message += "，#{result.invalid_count} 行缺少必填字段已跳过" unless result.invalid_count.zero?
      flash[:success] = message
    elsif result.invalid_count > 0
      flash[:warning] = "没有新帐号需要导入（#{result.skipped_count} 个已存在，#{result.invalid_count} 行缺少必填字段）"
    else
      flash[:warning] = "没有新帐号需要导入（#{result.skipped_count} 个已存在）"
    end

    redirect_to accounts_path
  rescue ArgumentError => e
    flash[:error] = truncate_error(e.message)
    redirect_to import_rednote_page_accounts_path
  rescue StandardError => e
    flash[:error] = truncate_error("导入失败：#{e.message}")
    redirect_to import_rednote_page_accounts_path
  end

  def import_rednote_file
    unless params[:rednote_csv_file].present?
      flash[:error] = "请上传 CSV 文件"
      redirect_to import_rednote_page_accounts_path and return
    end

    result = Rednote::Importer.import_file(params[:rednote_csv_file])

    if result.errors.any?
      flash[:error] = truncate_error("部分帐号导入失败：#{result.errors.join('; ')}")
    elsif result.imported_count > 0
      message = "成功导入 #{result.imported_count} 个小红书帐号（#{result.skipped_count} 个重复已跳过）"
      message += "，#{result.invalid_count} 行缺少必填字段已跳过" unless result.invalid_count.zero?
      flash[:success] = message
    elsif result.invalid_count > 0
      flash[:warning] = "没有新帐号需要导入（#{result.skipped_count} 个已存在，#{result.invalid_count} 行缺少必填字段）"
    else
      flash[:warning] = "没有新帐号需要导入（#{result.skipped_count} 个已存在）"
    end

    redirect_to accounts_path
  rescue ArgumentError => e
    flash[:error] = truncate_error(e.message)
    redirect_to import_rednote_page_accounts_path
  rescue StandardError => e
    flash[:error] = truncate_error("导入失败：#{e.message}")
    redirect_to import_rednote_page_accounts_path
  end

  def import_rednote_search
    query = params[:profile_id].to_s.strip

    if query.blank?
      flash[:error] = "请输入用户 ID 或名称"
      redirect_to import_rednote_page_accounts_path and return
    end

    # If input looks like a user ID (24-char hex), search by ID; otherwise search by name
    if query.match?(/\A[0-9a-f]{24}\z/i)
      @user_info = AccountResolver.search_rednote_by_id(query)

      unless @user_info.present?
        flash[:warning] = "未找到该用户"
        redirect_to import_rednote_page_accounts_path and return
      end

      render :import_preview_rednote
    else
      @keyword = query
      @search_results = AccountResolver.search_rednote(query)

      if @search_results.empty?
        flash[:warning] = "未搜索到匹配的帐号"
        redirect_to import_rednote_page_accounts_path and return
      end

      render :import_preview_rednote_search
    end
  rescue RednoteApiClient::ApiKeyMissingError, TikHubApiClient::ApiKeyMissingError => e
    flash[:error] = "API Key 未配置，请先在设置页面配置"
    redirect_to import_rednote_page_accounts_path
  rescue RednoteApiClient::ApiError, TikHubApiClient::ApiError => e
    flash[:error] = truncate_error("查找失败：#{e.message}")
    redirect_to import_rednote_page_accounts_path
  rescue StandardError => e
    flash[:error] = truncate_error("查找失败：#{e.message}")
    redirect_to import_rednote_page_accounts_path
  end

  def import_rednote_by_id
    accounts_data = params[:accounts_data]&.to_unsafe_h || {}

    # Filter to only selected accounts
    selected = accounts_data.select { |_, data| data["selected"] == "1" || data[:selected] == "1" }

    if selected.blank?
      flash[:error] = "请至少选择一个帐号"
      redirect_to import_rednote_page_accounts_path and return
    end

    rows = selected.map do |user_id, data|
      {
        "user_id"  => user_id.to_s,
        "nickname" => data["nickname"] || data[:nickname],
        "image"    => data["image"] || data[:image]
      }
    end

    result = Rednote::Importer.import_search_rows(rows)

    if result.errors.any?
      flash[:error] = truncate_error("部分帐号导入失败：#{result.errors.join('; ')}")
    elsif result.imported_count > 0
      flash[:success] = "成功导入 #{result.imported_count} 个小红书帐号（#{result.skipped_count} 个重复已跳过）"
    else
      flash[:warning] = "没有新帐号需要导入（#{result.skipped_count} 个已存在）"
    end

    redirect_to accounts_path
  rescue ArgumentError => e
    flash[:error] = truncate_error(e.message)
    redirect_to import_rednote_page_accounts_path
  rescue StandardError => e
    flash[:error] = truncate_error("导入失败：#{e.message}")
    redirect_to import_rednote_page_accounts_path
  end

  def import_twitter_search
    raw_input = params[:twitter_screen_names].to_s.strip
    if raw_input.blank?
      flash[:error] = "请输入 Twitter 用户名"
      redirect_to import_twitter_page_accounts_path and return
    end

    # Support comma-separated or newline-separated screen names or URLs
    screen_names = raw_input.split(/[\s,]+/).map { |n| AccountResolver.normalize_twitter_screen_name(n) }.reject(&:blank?).uniq

    if screen_names.empty?
      flash[:error] = "请输入有效的 Twitter 用户名"
      redirect_to import_twitter_page_accounts_path and return
    end

    @search_results = []
    screen_names.each do |name|
      users = AccountResolver.search_twitter(name)
      @search_results.concat(users) if users.any?
    rescue TwitterApiClient::ApiError => e
      Rails.logger.warn("Twitter lookup failed for @#{name}: #{e.message}")
    end

    if @search_results.empty?
      flash[:warning] = "未找到匹配的 Twitter 帐号"
      redirect_to import_twitter_page_accounts_path and return
    end

    render :import_preview_twitter
  rescue TwitterApiClient::ApiKeyMissingError => e
    flash[:error] = "Twitter cookies 未配置，请先在设置页面配置"
    redirect_to import_twitter_page_accounts_path
  rescue StandardError => e
    flash[:error] = truncate_error("搜索失败：#{e.message}")
    redirect_to import_twitter_page_accounts_path
  end

  def import_twitter
    selected_ids = Array(params[:selected_user_ids]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    accounts_data = params[:accounts_data] || {}

    if selected_ids.empty?
      flash[:error] = "请至少选择一个帐号"
      redirect_to import_twitter_page_accounts_path and return
    end

    rows = selected_ids.filter_map do |uid|
      data = accounts_data[uid] || accounts_data[uid.to_sym]
      next unless data.respond_to?(:[])

      {
        "user_id" => uid,
        "screen_name" => data["screen_name"] || data[:screen_name],
        "name" => data["name"] || data[:name],
        "image" => data["image"] || data[:image]
      }
    end

    result = Twitter::Importer.import_search_rows(rows)

    if result.errors.any?
      flash[:error] = truncate_error("部分帐号导入失败：#{result.errors.join('; ')}")
    elsif result.imported_count > 0
      flash[:success] = "成功导入 #{result.imported_count} 个 Twitter 帐号（#{result.skipped_count} 个重复已跳过）"
    else
      flash[:warning] = "没有新帐号需要导入（#{result.skipped_count} 个已存在）"
    end

    redirect_to accounts_path
  rescue ArgumentError => e
    flash[:error] = truncate_error(e.message)
    redirect_to import_twitter_page_accounts_path
  rescue StandardError => e
    flash[:error] = truncate_error("导入失败：#{e.message}")
    redirect_to import_twitter_page_accounts_path
  end

  def import_twitter_file
    unless params[:csv_file].present?
      flash[:error] = "请上传 CSV 文件"
      redirect_to import_twitter_page_accounts_path and return
    end

    result = Twitter::Importer.import_file(params[:csv_file])

    if result.errors.any?
      flash[:error] = truncate_error("部分帐号导入失败：#{result.errors.join('; ')}")
    elsif result.imported_count > 0
      message = "成功导入 #{result.imported_count} 个 Twitter 帐号（#{result.skipped_count} 个重复已跳过）"
      message += "，#{result.invalid_count} 行缺少必填字段已跳过" unless result.invalid_count.zero?
      flash[:success] = message
    elsif result.invalid_count > 0
      flash[:warning] = "没有新帐号需要导入（#{result.skipped_count} 个已存在，#{result.invalid_count} 行无效）"
    else
      flash[:warning] = "没有新帐号需要导入（#{result.skipped_count} 个已存在）"
    end

    redirect_to accounts_path
  rescue ArgumentError => e
    flash[:error] = truncate_error(e.message)
    redirect_to import_twitter_page_accounts_path
  rescue StandardError => e
    flash[:error] = truncate_error("导入失败：#{e.message}")
    redirect_to import_twitter_page_accounts_path
  end

  def resolve_weread_mp_id
    @account = Account.find(params[:id])
    url = params[:article_url].to_s.strip

    if url.blank?
      flash[:error] = "请输入微信公众号文章链接"
      redirect_to account_path(@account) and return
    end

    unless url.include?("mp.weixin.qq.com")
      flash[:error] = "请输入有效的微信公众号文章链接（包含 mp.weixin.qq.com）"
      redirect_to account_path(@account) and return
    end

    result = WereadNativeApiClient.get_mp_info(url)
    if result.is_a?(Array) && result.any? && result.first["id"].present?
      mp_info = result.first
      new_mp_id = mp_info["id"]
      @account.metadata ||= {}
      @account.metadata["weread_mp_id"] = new_mp_id
      @account.save!
      flash[:success] = "WeRead mpId 已更新: #{new_mp_id}（公众号: #{mp_info['name']}）"
    else
      flash[:error] = "未能从该链接解析到公众号信息，请确认链接有效"
    end
    redirect_to account_path(@account)
  rescue WereadNativeApiClient::ApiError => e
    flash[:error] = "解析失败：#{e.message}"
    redirect_to account_path(@account)
  rescue StandardError => e
    Rails.logger.error("[WeRead] resolve_mp_id error: #{e.message}")
    flash[:error] = "解析失败：#{e.message[0..200]}"
    redirect_to account_path(@account)
  end

  private

  def account_params
    params.require(:account).permit(:nickname)
  end

  def require_website_account!(account)
    return if account.website?

    raise WebsiteCrawler::ListingRule::InvalidRule, "只有官网帐号可以配置抓取规则"
  end

  def success_message_for(result)
    message = "成功导入 #{result.imported_count} 个帐号（#{result.skipped_count} 个重复已跳过）"
    return message if result.invalid_count.zero?

    "#{message}，#{result.invalid_count} 行缺少必填字段已跳过"
  end

  def truncate_error(message, max_length = MAX_FLASH_ERROR_LENGTH)
    return message if message.length <= max_length
    "#{message[0...max_length]}..."
  end

  def resolve_bulk_account_ids
    if params[:select_all] == "true"
      if params[:q].present?
        q_params = params[:q]
        q_hash = q_params.respond_to?(:to_unsafe_h) ? q_params.to_unsafe_h : q_params.to_h
        scope = Account.ransack(q_hash).result
      else
        scope = Account.all
      end
      scope.pluck(:id)
    else
      Array(params[:account_ids]).map(&:to_i).reject(&:zero?)
    end
  end
end
