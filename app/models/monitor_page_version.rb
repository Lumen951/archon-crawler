require "digest"

# An immutable snapshot of a page's extracted content. Change detection hashes
# the normalized content and only stores a new version when the hash differs
# from the page's current_version (see docs/website-monitor.md §8).
# == Schema Information
#
# Table name: monitor_page_versions
#
#  id              :bigint           not null, primary key
#  captured_at     :datetime         not null
#  content         :text
#  content_hash    :string           not null
#  content_length  :integer          default(0), not null
#  fetched_via     :string
#  http_status     :integer
#  title           :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  monitor_page_id :bigint           not null
#
# Indexes
#
#  index_monitor_page_versions_on_monitor_page_id        (monitor_page_id)
#  index_monitor_page_versions_on_page_and_content_hash  (monitor_page_id,content_hash)
#  index_monitor_page_versions_on_page_and_created_at    (monitor_page_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (monitor_page_id => monitor_pages.id)
#
class MonitorPageVersion < ApplicationRecord
  belongs_to :monitor_page

  scope :recent, -> { order(created_at: :desc) }

  def self.digest(content)
    Digest::SHA256.hexdigest(content.to_s)
  end
end
