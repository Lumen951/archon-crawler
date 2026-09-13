# A detected + LLM-analyzed change on a page. Merges the design's Change and
# Analysis concepts: what changed (change_type / changes) plus what it means
# (summary / importance / relevance / entities). `notified_at` is the seam for
# future notification delivery (Feishu, email, ...).
# == Schema Information
#
# Table name: monitor_changes
#
#  id                      :bigint           not null, primary key
#  analysis_status         :string           default("pending"), not null
#  change_items            :jsonb
#  change_type             :string
#  diff_added              :integer          default(0), not null
#  diff_removed            :integer          default(0), not null
#  entities                :jsonb
#  importance              :integer          default(0), not null
#  notified_at             :datetime
#  refer_url               :string
#  relevance               :integer          default(0), not null
#  summary                 :text
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  account_id              :bigint           not null
#  crawl_task_id           :bigint
#  monitor_page_id         :bigint           not null
#  monitor_page_version_id :bigint
#  previous_version_id     :bigint
#
# Indexes
#
#  index_monitor_changes_on_account_id                 (account_id)
#  index_monitor_changes_on_account_id_and_created_at  (account_id,created_at)
#  index_monitor_changes_on_crawl_task_id              (crawl_task_id)
#  index_monitor_changes_on_importance                 (importance)
#  index_monitor_changes_on_monitor_page_id            (monitor_page_id)
#  index_monitor_changes_on_monitor_page_version_id    (monitor_page_version_id)
#  index_monitor_changes_on_refer_url                  (refer_url)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (crawl_task_id => crawl_tasks.id)
#  fk_rails_...  (monitor_page_id => monitor_pages.id)
#  fk_rails_...  (monitor_page_version_id => monitor_page_versions.id)
#
class MonitorChange < ApplicationRecord
  belongs_to :account
  belongs_to :monitor_page
  belongs_to :monitor_page_version, optional: true
  belongs_to :crawl_task, optional: true

  IMPORTANCE_THRESHOLD = 7

  scope :recent, -> { order(created_at: :desc) }
  scope :important, -> { where("importance >= ?", IMPORTANCE_THRESHOLD) }
  scope :unnotified, -> { where(notified_at: nil) }

  def important?
    importance.to_i >= IMPORTANCE_THRESHOLD
  end
end
