# == Schema Information
#
# Table name: crawl_task_accounts
#
#  id            :bigint           not null, primary key
#  completed_at  :datetime
#  error_message :text
#  started_at    :datetime
#  status        :integer          default(0), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  account_id    :bigint           not null
#  crawl_task_id :bigint           not null
#
# Indexes
#
#  idx_crawl_task_accounts_status              (crawl_task_id,status)
#  idx_crawl_task_accounts_unique              (crawl_task_id,account_id) UNIQUE
#  index_crawl_task_accounts_on_account_id     (account_id)
#  index_crawl_task_accounts_on_crawl_task_id  (crawl_task_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (crawl_task_id => crawl_tasks.id)
#
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
