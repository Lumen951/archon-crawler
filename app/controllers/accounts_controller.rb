class AccountsController < ApplicationController
  def index
    @accounts = Account.all.order(created_at: :desc)
  end

  def show
    @account = Account.find(params[:id])
    @articles = @account.articles.recent.page(params[:page]).per(25)
  end

  def import
    # Show import form
  end

  def search_preview
    keyword = params[:keyword].to_s.strip

    if keyword.blank?
      flash[:error] = "请输入搜索关键词"
      redirect_to import_accounts_path and return
    end

    @keyword = keyword
    @search_accounts = Accounts::Importer.search(keyword)

    if @search_accounts.empty?
      flash[:warning] = "未搜索到匹配的帐号"
      redirect_to import_accounts_path and return
    end

    render :import_preview
  rescue ArgumentError => e
    flash[:error] = e.message
    redirect_to import_accounts_path
  rescue WechatApiClient::ApiError => e
    flash[:error] = "搜索失败：#{e.message}"
    redirect_to import_accounts_path
  rescue StandardError => e
    flash[:error] = "搜索失败：#{e.message}"
    redirect_to import_accounts_path
  end

  def import_json
    result = if params[:json_text].present?
      Accounts::Importer.import_text(params[:json_text])
    elsif params[:json_file].present?
      Accounts::Importer.import_file(params[:json_file])
    else
      flash[:error] = "请提供 JSON 数据或上传文件"
      redirect_to import_accounts_path and return
    end

    if result.errors.any?
      flash[:error] = "部分帐号导入失败：#{result.errors.join('; ')}"
    elsif result.imported_count > 0
      flash[:success] = success_message_for(result)
    elsif result.invalid_count > 0
      flash[:warning] = "没有新帐号需要导入（#{result.skipped_count} 个已存在，#{result.invalid_count} 行缺少必填字段）"
    else
      flash[:warning] = "没有新帐号需要导入（#{result.skipped_count} 个已存在）"
    end

    redirect_to accounts_path
  rescue ArgumentError => e
    flash[:error] = e.message
    redirect_to accounts_path
  rescue StandardError => e
    flash[:error] = "导入失败：#{e.message}"
    redirect_to accounts_path
  end

  def import_search
    selected_fakeids = Array(params[:selected_fakeids]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    accounts_data = params[:accounts_data] || {}

    if selected_fakeids.empty?
      flash[:error] = "请至少选择一个帐号"
      redirect_to import_accounts_path and return
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
      flash[:error] = "部分帐号导入失败：#{result.errors.join('; ')}"
    elsif result.imported_count > 0
      flash[:success] = success_message_for(result)
    else
      flash[:warning] = "没有新帐号需要导入（#{result.skipped_count} 个已存在）"
    end

    redirect_to accounts_path
  rescue ArgumentError => e
    flash[:error] = e.message
    redirect_to import_accounts_path
  rescue WechatApiClient::ApiError => e
    flash[:error] = "搜索失败：#{e.message}"
    redirect_to import_accounts_path
  rescue StandardError => e
    flash[:error] = "导入失败：#{e.message}"
    redirect_to import_accounts_path
  end

  def crawl
    @account = Account.find(params[:id])

    # unless Option.api_key_valid?
    #   flash[:error] = "API 密钥已过期。请在设置中更新。"
    #   redirect_to accounts_path and return
    # end

    if CrawlTask.active.exists?
      flash[:error] = "已有活跃的抓取任务"
      redirect_to account_path(@account) and return
    end

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

  def import_rednote_json
    result = if params[:rednote_json_text].present?
      Rednote::Importer.import_text(params[:rednote_json_text])
    elsif params[:rednote_json_file].present?
      Rednote::Importer.import_file(params[:rednote_json_file])
    else
      flash[:error] = "请提供 JSON 数据或上传文件"
      redirect_to import_accounts_path and return
    end

    if result.errors.any?
      flash[:error] = "部分帐号导入失败：#{result.errors.join('; ')}"
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
    flash[:error] = e.message
    redirect_to accounts_path
  rescue StandardError => e
    flash[:error] = "导入失败：#{e.message}"
    redirect_to accounts_path
  end

  private

  def success_message_for(result)
    message = "成功导入 #{result.imported_count} 个帐号（#{result.skipped_count} 个重复已跳过）"
    return message if result.invalid_count.zero?

    "#{message}，#{result.invalid_count} 行缺少必填字段已跳过"
  end
end


