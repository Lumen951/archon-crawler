class CrawlTask < ApplicationRecord
  has_many :crawl_logs, dependent: :destroy
  has_many :articles, dependent: :nullify
  has_many :crawl_task_accounts, dependent: :destroy

  after_update_commit :broadcast_task_updates

  enum :status, { pending: 0, running: 1, paused: 2, completed: 3, failed: 4 }

  scope :active, -> { where(status: [:pending, :running]) }
  scope :recent, -> { order(created_at: :desc) }

  ERROR_THRESHOLD = 20

  def resolved_accounts
    if account_ids.present?
      Account.where(id: account_ids)
    else
      Account.active
    end
  end

  def effective_account_concurrency
    account_concurrency || Option.default_account_concurrency
  end

  def effective_article_concurrency
    article_concurrency || Option.default_article_concurrency
  end

  def error_threshold_exceeded?
    error_count >= ERROR_THRESHOLD
  end

  def increment_error_count!
    increment!(:error_count)
    broadcast_updates
  end

  def increment_progress!
    increment!(:progress)
    broadcast_updates
  end

  def broadcast_updates
    broadcast_task_updates
  end

  def log(level, message, context: nil)
    CrawlLog.log(self, level, message, context: context)
  end

  def clear_old_logs
    crawl_logs.delete_all
  end

  def pause!
    update!(status: :paused)
  end

  def resume!
    # 重置 failed 的 account 为 pending，以便重试
    crawl_task_accounts.failed.update_all(status: :pending, error_message: nil, completed_at: nil)
    update!(status: :running, error_message: nil)
    CrawlJob.perform_later(id)
  end

  # 初始化帐号追踪记录（task 开始时调用）
  def setup_account_tracking!
    resolved_accounts.find_each do |account|
      crawl_task_accounts.find_or_create_by!(account: account)
    end
    update!(total: crawl_task_accounts.count)
  end

  # 只返回未完成的 account（用于 resume 时跳过已完成的）
  def incomplete_accounts
    Account.where(id: crawl_task_accounts.incomplete.select(:account_id))
  end

  def all_accounts_completed?
    crawl_task_accounts.incomplete.count.zero?
  end

  def completed_account_count
    crawl_task_accounts.completed.count
  end

  def failed_account_count
    crawl_task_accounts.failed.count
  end

  def mark_complete!
    log(:info, "抓取成功完成")
    update!(status: :completed, completed_at: Time.current)
    # 只更新实际完成的 account 的 last_crawled_at
    Account.where(id: crawl_task_accounts.completed.select(:account_id)).update_all(last_crawled_at: Time.current)
  end

  def mark_failed!(error)
    log(:error, "抓取失败：#{error}")
    update!(status: :failed, error_message: error, completed_at: Time.current)
  end

  def progress_percentage
    return 0 if total.nil? || total.zero?
    ((progress.to_f / total) * 100).round(1)
  end

  def account_names
    resolved_accounts.pluck(:nickname)
  end

  def account_count
    if account_ids.present?
      account_ids.size
    else
      Account.active.count
    end
  end

  private

  def broadcast_task_updates
    broadcast_replace_to(
      :crawl_tasks,
      target: ActionView::RecordIdentifier.dom_id(self, :row),
      partial: "crawl_tasks/task_row",
      locals: { task: self }
    )

    broadcast_replace_to(
      :crawl_tasks,
      target: ActionView::RecordIdentifier.dom_id(self, :card),
      partial: "crawl_tasks/task_card",
      locals: { task: self }
    )

    broadcast_replace_to(
      [self, :show],
      target: ActionView::RecordIdentifier.dom_id(self, :show_body),
      partial: "crawl_tasks/show_body",
      locals: { crawl_task: self, recent_logs: crawl_logs.recent.limit(50) }
    )
  end
end
