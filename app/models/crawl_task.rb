class CrawlTask < ApplicationRecord
  has_many :crawl_logs, dependent: :destroy

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
    account_concurrency || SystemConfig.default_account_concurrency
  end

  def effective_article_concurrency
    article_concurrency || SystemConfig.default_article_concurrency
  end

  def error_threshold_exceeded?
    error_count >= ERROR_THRESHOLD
  end

  def increment_error_count!
    increment!(:error_count)
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
    update!(status: :running)
    CrawlJob.perform_later(id)
  end

  def mark_complete!
    log(:info, "抓取成功完成")
    update!(status: :completed, completed_at: Time.current)
    resolved_accounts.update_all(last_crawled_at: Time.current)
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
end
