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
      flash[:error] = "部分公众号导入失败：#{result.errors.join('; ')}"
    elsif result.imported_count > 0
      flash[:success] = success_message_for(result)
    elsif result.invalid_count > 0
      flash[:warning] = "没有新公众号需要导入（#{result.skipped_count} 个已存在，#{result.invalid_count} 行缺少必填字段）"
    else
      flash[:warning] = "没有新公众号需要导入（#{result.skipped_count} 个已存在）"
    end

    redirect_to accounts_path
  rescue ArgumentError => e
    flash[:error] = e.message
    redirect_to accounts_path
  rescue StandardError => e
    flash[:error] = "导入失败：#{e.message}"
    redirect_to accounts_path
  end

  def crawl
    @account = Account.find(params[:id])

    unless SystemConfig.api_key_valid?
      flash[:error] = "API 密钥已过期。请在设置中更新。"
      redirect_to accounts_path and return
    end

    if CrawlTask.active.exists?
      flash[:error] = "已有活跃的抓取任务"
      redirect_to account_path(@account) and return
    end

    begin
      @account.crawl!
      flash[:success] = "已为 #{@account.nickname} 启动抓取"
    rescue StandardError => e
      flash[:error] = "启动抓取失败：#{e.message}"
    end

    redirect_to account_path(@account)
  end

  def toggle_status
    @account = Account.find(params[:id])
    @account.update!(status: @account.active? ? :inactive : :active)
    flash[:success] = "公众号状态已更新"
    redirect_to accounts_path
  end

  private

  def success_message_for(result)
    message = "成功导入 #{result.imported_count} 个公众号（#{result.skipped_count} 个重复已跳过）"
    return message if result.invalid_count.zero?

    "#{message}，#{result.invalid_count} 行缺少必填字段已跳过"
  end
end

