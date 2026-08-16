require "async"
require "async/semaphore"

# Daily job that downloads WeChat article content (content_html) for every
# WeChat article still missing it. Content download is strictly rate-limited
# (default 5 req/min), so a single run can outlast a day. A new run therefore
# checks the previous run's job_id + heartbeat: a fresh heartbeat means the
# previous run is still alive → skip; a stale heartbeat means it's dead → take
# over. Articles are processed newest-first (published_at DESC).
class WechatContentDownloadJob < ApplicationJob
  queue_as :default

  # Arbitrary int64 key for pg_advisory_xact_lock, unique to this job. The
  # transaction-scoped lock only guards the short claim section in claim_task.
  ADVISORY_LOCK_KEY = 7_285_526_931

  # A run whose heartbeat is older than this is considered dead and replaced.
  HEARTBEAT_STALE_THRESHOLD = 1.hour

  BATCH_SIZE = 50

  def perform
    task = claim_task
    if task.nil?
      Rails.logger.info("[WechatContentDownloadJob] previous run still active, skipping")
      return
    end

    task.log(:info, "开始下载缺失正文的微信文章...")

    ids = Article.wechat_missing_content.order(published_at: :desc).pluck(:id)
    task.update!(articles_total: ids.size)

    if ids.empty?
      task.log(:info, "没有缺失正文的微信文章，无需下载")
      task.update!(status: :completed, finished_at: Time.current, heartbeat_at: Time.current)
      return
    end

    article_concurrency = Option.default_article_concurrency

    Async do
      semaphore = Async::Semaphore.new(article_concurrency)

      ids.each_slice(BATCH_SIZE) do |id_batch|
        articles = Article.where(id: id_batch).order(published_at: :desc)
        WechatCrawler.download_article_contents(
          articles, task, semaphore,
          on_article_complete: ->(_article, ok) { task.record_download!(ok) }
        )
      end
    end

    task.update!(status: :completed, finished_at: Time.current, heartbeat_at: Time.current)
    task.log(:info, "正文下载完成：成功 #{task.articles_downloaded} 篇，失败 #{task.articles_failed} 篇")
  rescue StandardError => e
    task&.update!(status: :failed, error_message: e.message, finished_at: Time.current)
    task&.log(:error, "正文下载任务失败：#{e.message}")
    raise
  end

  private

  # Atomically claim the right to run: mark stale runs as dead, then create a
  # new running task only if no other run is still alive. Returns nil when
  # another run is active and this invocation should skip.
  def claim_task
    claimed = nil

    ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_KEY})")

      WechatContentDownloadTask.active
        .where("heartbeat_at < ?", HEARTBEAT_STALE_THRESHOLD.ago)
        .update_all(
          status: WechatContentDownloadTask.statuses[:stale],
          finished_at: Time.current,
          error_message: "心跳过期，被新任务接管"
        )

      unless WechatContentDownloadTask.active.exists?
        claimed = WechatContentDownloadTask.create!(
          job_id: job_id,
          status: :running,
          started_at: Time.current,
          heartbeat_at: Time.current
        )
      end
    end

    claimed
  end
end
