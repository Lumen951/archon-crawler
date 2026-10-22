class PaperSyncRun < ApplicationRecord
  belongs_to :paper_subscription

  enum :status, {
    queued: "queued", running: "running", completed: "completed",
    failed: "failed", paused: "paused"
  }

  def active?
    (queued? || running?) && updated_at > 10.minutes.ago
  end

  def resumable?
    !completed? && !active? && (!retry_at || retry_at <= Time.current)
  end

  def enqueue!(attempt: 0, wait: 0)
    queued = PaperAuthorSyncJob.set(wait: wait.seconds).perform_later(id, run_token, next_offset, attempt)
    raise ActiveJob::EnqueueError unless queued

    true
  rescue StandardError => e
    self.class.where(id: id, run_token: run_token, next_offset: next_offset).update_all(
      status: "failed", error_message: "回溯任务未能入队，请点击继续回溯", updated_at: Time.current
    )
    Rails.logger.warn("Paper author sync enqueue failed: #{e.class}")
    false
  end

  def status_label
    { "queued" => "等待执行", "running" => "正在回溯", "completed" => "本轮查询已遍历",
      "failed" => "回溯中断", "paused" => "已暂停" }.fetch(status)
  end
end
