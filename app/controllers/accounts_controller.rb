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
    begin
      json_data = if params[:json_text].present?
                    # Parse from textarea
                    JSON.parse(params[:json_text])
                  elsif params[:json_file].present?
                    # Parse from uploaded file
                    JSON.parse(params[:json_file].read)
                  else
                    flash[:error] = "请提供 JSON 数据或上传文件"
                    redirect_to import_accounts_path and return
                  end

      # Validate JSON structure
      unless json_data.is_a?(Hash) && json_data["accounts"].is_a?(Array)
        flash[:error] = "无效的 JSON 格式。期望结构：{ \"accounts\": [...] }"
        redirect_to import_accounts_path and return
      end

      imported = 0
      skipped = 0
      errors = []

      json_data["accounts"].each do |data|
        next unless data["fakeid"].present? && data["nickname"].present?

        account = Account.find_or_initialize_by(fakeid: data["fakeid"])

        if account.new_record?
          account.nickname = data["nickname"]
          account.round_head_img = data["round_head_img"]
          account.status = :active
          account.total_articles = data["articles"] || 0

          if account.save
            imported += 1
          else
            errors << "#{data['nickname']}: #{account.errors.full_messages.join(', ')}"
          end
        else
          skipped += 1
        end
      end

      if errors.any?
        flash[:error] = "部分公众号导入失败：#{errors.join('; ')}"
      elsif imported > 0
        flash[:success] = "成功导入 #{imported} 个公众号（#{skipped} 个重复已跳过）"
      else
        flash[:warning] = "没有新公众号需要导入（#{skipped} 个已存在）"
      end

    rescue JSON::ParserError => e
      flash[:error] = "无效的 JSON 格式：#{e.message}"
    rescue StandardError => e
      flash[:error] = "导入失败：#{e.message}"
    end

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
end
