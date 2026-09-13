# == Schema Information
#
# Table name: wechat_url_import_items
#
#  id                        :bigint           not null, primary key
#  error_message             :text
#  processed_at              :datetime
#  started_at                :datetime
#  status                    :integer          default(0), not null
#  url                       :string           not null
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  account_id                :bigint
#  wechat_url_import_task_id :bigint           not null
#
# Indexes
#
#  index_wechat_url_import_items_on_account_id                 (account_id)
#  index_wechat_url_import_items_on_status                     (status)
#  index_wechat_url_import_items_on_task_and_url               (wechat_url_import_task_id,url) UNIQUE
#  index_wechat_url_import_items_on_wechat_url_import_task_id  (wechat_url_import_task_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (wechat_url_import_task_id => wechat_url_import_tasks.id)
#
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
