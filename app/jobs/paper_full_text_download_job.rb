class PaperFullTextDownloadJob < ApplicationJob
  queue_as :default

  def perform(id, token, attempt = 0)
    PaperFullText.connection_pool.with_connection do |connection|
      key = connection.quote("paper-full-text:#{Integer(id)}")
      return unless connection.select_value("SELECT pg_try_advisory_lock(hashtextextended(#{key}, 0))")

      begin
        download(id, token, attempt)
      ensure
        connection.execute("SELECT pg_advisory_unlock(hashtextextended(#{key}, 0))")
      end
    end
  end

  private

  def download(id, token, attempt)
    record = PaperFullText.find_by(id: id, run_token: token)
    return unless record && (record.status_queued? || record.status_downloading?)
    return if record.retry_at && record.retry_at > Time.current

    record.update!(status: :downloading, error_message: nil, retry_at: nil)
    PaperFullTextDownloader.new(record).download!
  rescue PaperImporter::TemporaryError => e
    wait = [ 60 * (2**attempt), e.retry_after.to_i ].max
    if attempt < 2 && wait <= 3600
      record.update!(status: :queued, retry_at: wait.seconds.from_now,
        error_message: "#{e.message}，#{wait} 秒后重试（第 #{attempt + 1}/2 次）")
      begin
        queued = self.class.set(wait: wait.seconds).perform_later(id, token, attempt + 1)
        raise ActiveJob::EnqueueError unless queued
      rescue StandardError => enqueue_error
        Rails.logger.warn("Paper full text retry enqueue failed: #{enqueue_error.class}")
        record.update!(status: :failed, error_message: "全文自动重试未能入队，请稍后重试")
      end
    else
      record.update!(status: :failed, retry_at: e.retry_after.to_i.seconds.from_now,
        error_message: "#{e.message}；自动重试已停止，请稍后重试")
    end
  rescue PaperFullTextDownloader::Unavailable
    record.update!(status: :unavailable, error_message: "此版本暂时没有可下载的 HTML，可通过来源链接阅读")
  rescue PaperImporter::FetchError => e
    record.update!(status: :failed, error_message: e.message)
  rescue StandardError => e
    Rails.logger.warn("Paper full text download failed: #{e.class}")
    record&.update!(status: :failed, error_message: "全文处理失败，请稍后重试")
  end
end
