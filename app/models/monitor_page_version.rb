require "digest"

# An immutable snapshot of a page's extracted content. Change detection hashes
# the normalized content and only stores a new version when the hash differs
# from the page's current_version (see docs/website-monitor.md §8).
class MonitorPageVersion < ApplicationRecord
  belongs_to :monitor_page

  scope :recent, -> { order(created_at: :desc) }

  def self.digest(content)
    Digest::SHA256.hexdigest(content.to_s)
  end
end
