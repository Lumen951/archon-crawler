class WechatUrlImportTask < ApplicationRecord
  has_many :items, class_name: "WechatUrlImportItem", dependent: :destroy

  enum :status, { pending: 0, running: 1, completed: 2, failed: 3 }

  scope :recent, -> { order(created_at: :desc) }
  scope :active, -> { where(status: [:pending, :running]) }

  def progress_percentage
    return 0 if total_count.zero?

    ((processed_count.to_f / total_count) * 100).round(1)
  end

  def mark_running!
    with_lock do
      return false unless pending?

      update!(status: :running, started_at: started_at || Time.current)
    end
    true
  end

  def record_created!(item, account)
    item.update!(status: :created, account: account, processed_at: Time.current, started_at: item.started_at || Time.current)
    increment_progress!(:created_count)
  end

  def record_found!(item, account)
    item.update!(status: :found, account: account, processed_at: Time.current, started_at: item.started_at || Time.current)
    increment_progress!(:found_count)
  end

  def record_failed!(item, message)
    item.update!(status: :failed, error_message: message.to_s.first(500), processed_at: Time.current, started_at: item.started_at || Time.current)
    increment_progress!(:failed_count)
  end

  def finish!
    reload
    update!(status: failed_count.zero? ? :completed : :failed, completed_at: Time.current)
  end

  private

  def increment_progress!(counter)
    raise ArgumentError, "invalid counter" unless %w[created_count found_count failed_count].include?(counter.to_s)

    self.class.where(id: id).update_all(
      ["processed_count = processed_count + 1, #{counter} = #{counter} + 1, updated_at = ?", Time.current]
    )
  end
end
