class CrawlTask < ApplicationRecord
  has_many :crawl_logs, dependent: :destroy
  has_many :articles, dependent: :nullify
  has_many :crawl_task_accounts, dependent: :destroy

  enum :status, { pending: 0, running: 1, paused: 2, completed: 3, failed: 4 }

  scope :active, -> { where(status: [:pending, :running]) }
  scope :terminal, -> { where(status: [:completed, :failed]) }
  scope :recent, -> { order(created_at: :desc) }

  def self.cleanup_old_tasks(older_than: 1.week.ago)
    terminal.where('created_at < ?', older_than).destroy_all.size
  end

  ERROR_THRESHOLD = 50
  MAX_RETRIES = 5

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

  # When `platform_key` is given (e.g. an Account subclass name like
  # "WechatAccount"), only that platform's error count is checked, so a
  # struggling platform (e.g. WeChat) doesn't halt crawling for the others
  # (e.g. Rednote, Twitter). Without a platform_key, falls back to the
  # task-wide total.
  def error_threshold_exceeded?(platform_key = nil)
    if platform_key
      platform_error_count(platform_key) >= ERROR_THRESHOLD
    else
      error_count >= ERROR_THRESHOLD
    end
  end

  def platform_error_count(platform_key)
    (platform_error_counts || {})[platform_key.to_s].to_i
  end

  def increment_error_count!(platform_key = nil)
    increment!(:error_count)

    return if platform_key.nil?

    counts = (platform_error_counts || {}).dup
    counts[platform_key.to_s] = counts[platform_key.to_s].to_i + 1
    update!(platform_error_counts: counts)
  end

  # 立即标记某平台为失败（如微信读书账号池耗尽，任何账号都无法继续抓取）。
  # 复用 error_threshold_exceeded? 的跳过逻辑，使该平台剩余账号尽快跳过，
  # 其他平台不受影响。
  def fail_platform!(platform_key)
    counts = (platform_error_counts || {}).dup
    counts[platform_key.to_s] = ERROR_THRESHOLD
    update!(platform_error_counts: counts)
  end

  def increment_progress!
    increment!(:progress)
  end

  def log(level, message, context: nil)
    CrawlLog.log(self, level, message, context: context)
  end

  def pause!
    update!(status: :paused)
  end

  def resume!
    cancel_scheduled_job!
    update!(status: :pending, retry_count: 0, scheduled_job_id: nil)
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

  # Mark complete if no failed accounts; otherwise schedule a retry (up to MAX_RETRIES times)
  def mark_complete_or_schedule_retry!
    if failed_account_count.zero?
      mark_complete!
    elsif can_retry?
      delay = retry_delay_minutes
      new_count = retry_count + 1
      job = CrawlJob.set(wait: delay.minutes).perform_later(id)
      log(:warn, "有 #{failed_account_count} 个帐号抓取失败，#{delay} 分钟后自动重试 (#{new_count}/#{MAX_RETRIES})")
      update!(status: :failed, error_message: "#{failed_account_count} 个帐号抓取失败，#{delay} 分钟后自动重试", completed_at: Time.current, retry_count: new_count, scheduled_job_id: job.job_id)
    else
      mark_failed!("有 #{failed_account_count} 个帐号抓取失败，已达到最大重试次数 (#{MAX_RETRIES})")
    end
  end

  def mark_failed!(error)
    log(:error, "抓取失败：#{error}")
    update!(status: :failed, error_message: error, completed_at: Time.current)
  end

  # Cancel the scheduled auto-retry job and keep the task in failed state.
  # Returns true if a scheduled job was found and cancelled.
  def cancel_scheduled_retry!
    cancelled = cancel_scheduled_job!
    update!(scheduled_job_id: nil, error_message: "#{failed_account_count} 个帐号抓取失败（已取消自动重试）")
    cancelled
  end

  def can_retry?
    retry_count < MAX_RETRIES
  end

  def retry_delay_minutes
    # Exponential backoff: 5, 10, 20, 40, 60 minutes (capped at 60)
    [5 * (2**retry_count), 60].min
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

  # Remove the SolidQueue scheduled job if it exists. Works across queue databases
  # because SolidQueue::Job connects to the queue DB automatically.
  def cancel_scheduled_job!
    return false if scheduled_job_id.blank?

    SolidQueue::Job.find_by(active_job_id: scheduled_job_id)&.destroy
    true
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
    # Queue database may not be configured (e.g. async adapter in dev).
    # The job won't fire anyway in that case — just clear the tracking.
    Rails.logger.warn("CrawlTask##{id}: could not cancel SolidQueue job #{scheduled_job_id}: #{e.message}")
    true
  end

end
