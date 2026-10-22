class PaperFullText < ApplicationRecord
  belongs_to :paper_source

  enum :status, {
    pending: "pending", queued: "queued", downloading: "downloading",
    ready: "ready", unavailable: "unavailable", failed: "failed"
  }, prefix: true

  # The unique database index also covers concurrent create_or_find_by! calls.
  validates :version, numericality: { only_integer: true, greater_than: 0 }

  def self.storage_root
    Rails.root.join(Rails.env.test? ? "tmp/storage" : "storage", "paper_full_texts")
  end

  def directory
    self.class.storage_root.join(id.to_s)
  end

  def html_path
    directory.join("article.html")
  end

  def source_url
    "https://arxiv.org/html/#{paper_source.external_id}v#{version}"
  end

  def locally_available?
    status_ready? && File.file?(html_path) &&
      resources.keys.all? { |key| key.match?(/\A[0-9a-f]{64}\z/) && File.file?(directory.join(key)) }
  end

  def retryable?
    return false if retry_at && retry_at > Time.current

    return true if status_ready? && !locally_available?

    status_pending? || status_failed? || status_unavailable? ||
      ((status_queued? || status_downloading?) && updated_at < 30.minutes.ago)
  end

  def enqueue!
    token = nil
    with_lock do
      return false unless retryable?

      token = SecureRandom.uuid
      update!(status: :queued, run_token: token, error_message: nil, retry_at: nil)
    end
    queued = PaperFullTextDownloadJob.perform_later(id, token)
    raise ActiveJob::EnqueueError unless queued

    true
  rescue StandardError => e
    raise unless token

    self.class.where(id: id, run_token: token).update_all(
      status: "failed", error_message: "全文下载未能入队，请重试", updated_at: Time.current
    )
    Rails.logger.warn("Paper full text enqueue failed: #{e.class}")
    false
  end

  def status_label
    {
      "pending" => "待下载", "queued" => "等待下载", "downloading" => "正在下载",
      "ready" => "已保存到本地", "unavailable" => "来源未提供此版本的 HTML", "failed" => "下载失败"
    }.fetch(status)
  end
end
