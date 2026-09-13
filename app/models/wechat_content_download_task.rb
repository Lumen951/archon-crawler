# Tracks a single run of WechatContentDownloadJob. Uses job_id + heartbeat so a
# new daily run can detect whether the previous run is still alive (fresh
# heartbeat) or dead (stale heartbeat, taken over).
# == Schema Information
#
# Table name: wechat_content_download_tasks
#
#  id                  :bigint           not null, primary key
#  articles_downloaded :integer          default(0), not null
#  articles_failed     :integer          default(0), not null
#  articles_total      :integer          default(0), not null
#  error_message       :text
#  finished_at         :datetime
#  heartbeat_at        :datetime         not null
#  started_at          :datetime
#  status              :integer          default(0), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  job_id              :string           not null
#
# Indexes
#
#  index_wechat_content_download_tasks_on_job_id  (job_id) UNIQUE
#
class WechatContentDownloadTask < ApplicationRecord
  has_many :crawl_logs, as: :loggable, dependent: :destroy

  enum :status, { running: 0, completed: 1, failed: 2, stale: 3 }

  # A run whose heartbeat is older than this is considered dead and replaced.
  HEARTBEAT_STALE_THRESHOLD = 1.hour

  scope :active, -> { where(status: :running) }
  # An "alive" run is active with a fresh heartbeat. A stale active run is dead
  # and should be taken over, not treated as still running.
  scope :alive, -> { active.where("heartbeat_at >= ?", HEARTBEAT_STALE_THRESHOLD.ago) }
  scope :terminal, -> { where(status: [:completed, :failed, :stale]) }
  scope :recent, -> { order(created_at: :desc) }

  def processed_count
    articles_downloaded.to_i + articles_failed.to_i
  end

  def progress_percentage
    return 0 if articles_total.to_i.zero?
    ((processed_count.to_f / articles_total) * 100).round(1)
  end

  # Reuse CrawlLog with the same signature as CrawlTask#log, so this object can
  # be passed as the `crawl_task:` argument to Retryable / WechatCrawler and
  # their existing logging just works.
  def log(level, message, context: nil)
    CrawlLog.log(self, level, message, context: context)
  end

  # Called once per downloaded article: increment the counter and refresh the
  # heartbeat in a single SQL statement.
  def record_download!(success)
    col = success ? "articles_downloaded" : "articles_failed"
    self.class.where(id: id).update_all(["#{col} = #{col} + 1, heartbeat_at = ?", Time.current])
  end
end
