# == Schema Information
#
# Table name: event_research_task_accounts
#
#  id                     :bigint           not null, primary key
#  completed_at           :datetime
#  error_message          :text
#  started_at             :datetime
#  status                 :integer          default(0), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :bigint           not null
#  event_research_run_id  :bigint
#  event_research_task_id :bigint           not null
#
# Indexes
#
#  idx_event_research_task_accounts_status                       (event_research_task_id,status)
#  idx_event_research_task_accounts_unique                       (event_research_task_id,account_id) UNIQUE
#  index_event_research_task_accounts_on_account_id              (account_id)
#  index_event_research_task_accounts_on_event_research_run_id   (event_research_run_id)
#  index_event_research_task_accounts_on_event_research_task_id  (event_research_task_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (event_research_run_id => event_research_runs.id)
#  fk_rails_...  (event_research_task_id => event_research_tasks.id)
#
class EventResearchTaskAccount < ApplicationRecord
  belongs_to :event_research_task
  belongs_to :account
  belongs_to :event_research_run, optional: true

  enum :status, { pending: 0, running: 1, completed: 2, failed: 3, skipped: 4 }

  scope :incomplete, -> { where(status: [ :pending, :failed ]) }

  def mark_running!
    update!(status: :running, started_at: Time.current, error_message: nil)
  end

  def mark_completed!
    update!(status: :completed, completed_at: Time.current, error_message: nil)
  end

  def mark_failed!(error)
    update!(status: :failed, error_message: error.to_s.truncate(500), completed_at: Time.current)
  end

  def mark_skipped!(reason)
    update!(status: :skipped, error_message: reason.to_s.truncate(500), completed_at: Time.current)
  end
end
