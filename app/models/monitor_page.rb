# A monitored information source: a concrete page (news index, blog list,
# changelog, ...) tracked under a WebsiteAccount. Holds a pointer to its
# latest captured version (current_version) so change detection can diff
# against it. The old separate MonitorSource concept was folded into this
# model: a source IS the page we keep fetching.
class MonitorPage < ApplicationRecord
  belongs_to :account
  belongs_to :current_version, class_name: "MonitorPageVersion", optional: true

  has_many :monitor_changes, dependent: :destroy
  has_many :monitor_page_versions, dependent: :destroy

  validates :url, presence: true, uniqueness: { scope: :account_id }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(confidence: :desc, id: :asc) }
  # Pages RSS ordering: a page bubbles back to the top of the feed whenever its
  # content changes; pages never fetched sort by discovery time instead.
  scope :recently_updated, -> {
    order(Arel.sql("COALESCE(last_changed_at, last_checked_at, created_at) DESC"))
  }

  TYPE_LABELS = {
    "news" => "新闻", "blog" => "博客", "changelog" => "更新日志",
    "research" => "研究", "docs" => "文档", "pricing" => "定价", "updates" => "动态",
    "announcements" => "公告", "product" => "产品", "release" => "版本发布",
    "api_updates" => "API 更新", "model_releases" => "模型发布"
  }.freeze

  def type_label
    TYPE_LABELS.fetch(page_type, page_type.presence || "页面")
  end

  def baseline_ready?
    current_version_id.present?
  end

  def display_title
    title.presence || url
  end
end
