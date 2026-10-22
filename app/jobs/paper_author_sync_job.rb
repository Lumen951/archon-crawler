class PaperAuthorSyncJob < ApplicationJob
  queue_as :default

  def perform(id, token, offset, attempt = 0)
    run = PaperSyncRun.find_by(id: id)
    return unless eligible?(run, token, offset)

    PaperSource.connection_pool.with_connection do |connection|
      # Do not occupy a worker waiting behind a full-text download or another author.
      unless connection.select_value("SELECT pg_try_advisory_lock(72419001)")
        run.enqueue!(attempt: attempt, wait: 5)
        return
      end
      begin
        run.paper_subscription.with_lock do
          return unless eligible?(run.reload, token, offset)

          run.update!(status: :running, error_message: nil)
        end
        sleep 3
        discovery = PaperAuthorDiscovery.new(run)
        page = discovery.fetch_page
        run.paper_subscription.with_lock do
          return unless eligible?(run.reload, token, offset)

          discovery.save_page!(page)
          next_offset = offset + page.results.length
          run.update!(next_offset: next_offset, total_count: page.total, page_count: run.page_count + 1,
            status: next_offset >= page.total ? :completed : :queued,
            completed_at: next_offset >= page.total ? Time.current : nil, retry_at: nil)
        end
        run.enqueue! unless run.completed?
      ensure
        connection.execute("SELECT pg_advisory_unlock(72419001)")
      end
    end
  rescue PaperImporter::TemporaryError => e
    wait = [ 60 * (2**attempt), e.retry_after.to_i ].max
    scope = PaperSyncRun.where(id: id, run_token: token, next_offset: offset, status: %w[queued running])
    return if scope.update_all(status: attempt < 2 && wait <= 3600 ? "queued" : "failed",
      retry_at: wait.seconds.from_now, error_message: "#{e.message}；#{wait} 秒后可重试",
      updated_at: Time.current).zero?

    run.reload.enqueue!(attempt: attempt + 1, wait: wait) if attempt < 2 && wait <= 3600
  rescue StandardError => e
    message = e.is_a?(PaperImporter::FetchError) ? e.message : "回溯处理失败，请从检查点继续"
    Rails.logger.warn("Paper author sync failed: #{e.class}")
    PaperSyncRun.where(id: id, run_token: token, next_offset: offset, status: %w[queued running])
      .update_all(status: "failed", error_message: message.first(500), updated_at: Time.current)
  end

  private

  def eligible?(run, token, offset)
    run && run.run_token == token && run.next_offset == offset &&
      (run.queued? || run.running?) && run.paper_subscription.enabled? &&
      (!run.retry_at || run.retry_at <= Time.current)
  end
end
