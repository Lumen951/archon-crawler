class WechatUrlImportItem < ApplicationRecord
  belongs_to :wechat_url_import_task
  belongs_to :account, optional: true

  enum :status, { pending: 0, running: 1, created: 2, found: 3, failed: 4 }

  validates :url, presence: true, uniqueness: { scope: :wechat_url_import_task_id }

  scope :incomplete, -> { where(status: [:pending, :running]) }

  def claim!
    with_lock do
      return false unless pending?

      update!(status: :running, started_at: Time.current)
    end
    true
  end
end
