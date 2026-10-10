# == Schema Information
#
# Table name: event_research_notifications
#
#  id                    :bigint           not null, primary key
#  error_message         :text
#  kind                  :integer          default(0), not null
#  payload_digest        :string
#  payload_text          :text
#  sent_at               :datetime
#  status                :integer          default(0), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :bigint           not null
#  baseline_run_id       :bigint
#  event_research_run_id :bigint           not null
#
# Indexes
#
#  index_event_research_notifications_on_account_id             (account_id)
#  index_event_research_notifications_on_account_kind_status    (account_id,kind,status)
#  index_event_research_notifications_on_baseline_run_id        (baseline_run_id)
#  index_event_research_notifications_on_event_research_run_id  (event_research_run_id)
#  index_event_research_notifications_on_run_and_kind           (event_research_run_id,kind) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (baseline_run_id => event_research_runs.id)
#  fk_rails_...  (event_research_run_id => event_research_runs.id)
#
class EventResearchNotification < ApplicationRecord
  belongs_to :account
  belongs_to :event_research_run
  belongs_to :baseline_run, class_name: "EventResearchRun", optional: true

  enum :kind, { initial: 0, weekly: 1 }
  enum :status, { pending: 0, sent: 1, failed: 2, skipped: 3 }

  validates :event_research_run_id, uniqueness: { scope: :kind }

  scope :recent, -> { order(created_at: :desc) }

  def self.last_sent_baseline_for(account)
    where(account: account, status: statuses.fetch("sent"))
      .where(kind: kinds.values_at("initial", "weekly"))
      .recent
      .first
  end

  def self.last_sent_for(account, kind: :weekly)
    where(account: account, kind: kinds.fetch(kind.to_s), status: statuses.fetch("sent"))
      .where.not(event_research_run_id: nil)
      .recent
      .first
  end
end
