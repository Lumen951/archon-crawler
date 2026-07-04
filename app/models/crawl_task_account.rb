class CrawlTaskAccount < ApplicationRecord
  belongs_to :crawl_task
  belongs_to :account

  enum :status, { pending: 0, running: 1, completed: 2, failed: 3 }

  scope :incomplete, -> { where(status: [:pending, :failed]) }

  def mark_running!
    update!(status: :running, started_at: Time.current)
  end

  def mark_completed!
    update!(status: :completed, completed_at: Time.current)
  end

  def mark_failed!(error)
    update!(status: :failed, error_message: error.to_s.truncate(500), completed_at: Time.current)
  end
end
