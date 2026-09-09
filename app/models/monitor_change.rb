# A detected + LLM-analyzed change on a page. Merges the design's Change and
# Analysis concepts: what changed (change_type / changes) plus what it means
# (summary / importance / relevance / entities). `notified_at` is the seam for
# future notification delivery (Feishu, email, ...).
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
