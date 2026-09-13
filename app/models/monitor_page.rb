# A monitored information source: a concrete page (news index, blog list,
# changelog, ...) tracked under a WebsiteAccount. Holds a pointer to its
# latest captured version (current_version) so change detection can diff
# against it. The old separate MonitorSource concept was folded into this
# model: a source IS the page we keep fetching.
# == Schema Information
#
# Table name: monitor_pages
#
#  id                 :bigint           not null, primary key
#  active             :boolean          default(TRUE), not null
#  confidence         :float
#  discovered_via     :string
#  error_count        :integer          default(0), not null
#  fetched_via        :string
#  last_changed_at    :datetime
#  last_checked_at    :datetime
#  last_error         :text
#  last_status        :string
#  page_type          :string
#  sitemap_lastmod    :datetime
#  title              :string
#  url                :string           not null
#  versions_count     :integer          default(0), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :bigint           not null
#  current_version_id :bigint
#
# Indexes
#
#  index_monitor_pages_on_account_and_url     (account_id,url) UNIQUE
#  index_monitor_pages_on_account_id          (account_id)
#  index_monitor_pages_on_active              (active)
#  index_monitor_pages_on_current_version_id  (current_version_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
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
