class PaperImportJob < ApplicationJob
  queue_as :default

  def perform(task_id, retry_counts = {})
    # A disconnected worker releases this session lock; redelivery can resume
    # pending items without letting a second worker process the same task.
    PaperImportTask.connection_pool.with_connection do |connection|
      key = connection.quote("paper-import-task:#{Integer(task_id)}")
      locked = connection.select_value("SELECT pg_try_advisory_lock(hashtextextended(#{key}, 0))")
      return unless locked

      begin
        import_task(task_id, retry_counts)
      ensure
        connection.execute("SELECT pg_advisory_unlock(hashtextextended(#{key}, 0))")
      end
    end
  end

  private

  def import_task(task_id, retry_counts)
    task = PaperImportTask.find(task_id)
    return if task.completed? || task.failed? || !task.mark_running!
    task.update!(error_message: nil)

    task.items.order(:id).find_each do |item|
      next unless item.pending?

      begin
        paper = PaperImporter.import!(item.url)
        task.record_imported!(item, paper)
        enqueue_full_texts(paper)
      rescue PaperImporter::TemporaryError => e
        count = retry_counts.fetch(item.id.to_s, 0)
        wait = [ 60 * (2**count), e.retry_after.to_i ].max
        if count < 2 && wait <= 3600
          task.update!(error_message: "#{e.message}，#{wait} 秒后自动重试（第 #{count + 1}/2 次）")
          begin
            queued = self.class.set(wait: wait.seconds).perform_later(task.id, retry_counts.merge(item.id.to_s => count + 1))
            raise ActiveJob::EnqueueError unless queued
            return
          rescue StandardError => enqueue_error
            Rails.logger.warn("Paper retry enqueue failed: #{enqueue_error.class}")
            task.update!(error_message: nil)
            task.record_failed!(item, "#{e.message}；自动重试未能入队，请稍后重新导入")
          end
        else
          task.record_failed!(item, "#{e.message}；#{count >= 2 ? '自动重试已耗尽' : '来源要求等待超过一小时'}，请稍后重新导入")
        end
      rescue PaperImporter::UnsupportedUrl, PaperImporter::FetchError => e
        task.record_failed!(item, e.message)
      rescue StandardError => e
        Rails.logger.warn("Paper import failed for item ##{item.id}: #{e.class}")
        task.record_failed!(item, "导入失败，请稍后重试")
      end
    end
    task.finish! unless task.reload.completed? || task.failed?
  rescue ActiveRecord::RecordNotFound
    Rails.logger.warn("Paper import task ##{task_id} was not found")
  end

  def enqueue_full_texts(paper)
    paper.sources.arxiv.find_each do |source|
      record = source.prepare_full_text!
      record.enqueue! if record&.status_pending?
    end
  rescue StandardError => e
    # Metadata has already committed; a separate download failure must not undo it.
    Rails.logger.warn("Paper full text scheduling failed for paper ##{paper.id}: #{e.class}")
  end
end
