class PaperImportTask < ApplicationRecord
  belongs_to :user
  has_many :items, class_name: "PaperImportItem", dependent: :destroy

  enum :status, { pending: 0, running: 1, completed: 2, failed: 3 }

  scope :recent, -> { order(created_at: :desc) }

  def progress_percentage
    return 0 if total_count.zero?

    ((processed_count.to_f / total_count) * 100).round(1)
  end

  def mark_running!
    with_lock do
      return false unless pending? || running?

      update!(status: :running, started_at: started_at || Time.current)
    end
    true
  end

  def record_imported!(item, paper)
    item.with_lock do
      return unless item.pending?

      item.update!(status: :imported, paper: paper, processed_at: Time.current)
      increment_progress!(:imported_count)
    end
  end

  def record_failed!(item, message)
    item.with_lock do
      return unless item.pending?

      item.update!(status: :failed, error_message: message.to_s.first(500), processed_at: Time.current)
      increment_progress!(:failed_count)
    end
  end

  def finish!
    reload
    update!(status: failed_count.zero? ? :completed : :failed, completed_at: Time.current)
  end

  private

  def increment_progress!(counter)
    self.class.update_counters(id, { processed_count: 1, counter => 1, touch: true })
  end
end
