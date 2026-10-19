class PaperImportJob < ApplicationJob
  queue_as :default

  def perform(task_id)
    # A disconnected worker releases this session lock; redelivery can resume
    # pending items without letting a second worker process the same task.
    PaperImportTask.connection_pool.with_connection do |connection|
      key = connection.quote("paper-import-task:#{Integer(task_id)}")
      locked = connection.select_value("SELECT pg_try_advisory_lock(hashtextextended(#{key}, 0))")
      return unless locked

      begin
        import_task(task_id)
      ensure
        connection.execute("SELECT pg_advisory_unlock(hashtextextended(#{key}, 0))")
      end
    end
  end

  private

  def import_task(task_id)
    task = PaperImportTask.find(task_id)
    return if task.completed? || task.failed? || !task.mark_running!

    task.items.order(:id).find_each do |item|
      next unless item.pending?

      begin
        task.record_imported!(item, PaperImporter.import!(item.url))
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
end
