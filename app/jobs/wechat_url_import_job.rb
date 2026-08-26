class WechatUrlImportJob < ApplicationJob
  queue_as :default

  def perform(task_id)
    task = WechatUrlImportTask.find(task_id)
    return if task.completed? || task.failed?

    return unless task.mark_running!

    task.items.order(:id).find_each do |item|
      next unless item.claim!

      begin
        result = AccountResolver.resolve_wechat_by_url(item.url)
        account = result.account

        if account && result.status == "created"
          task.record_created!(item, account)
        elsif account && result.status == "found"
          task.record_found!(item, account)
        else
          task.record_failed!(item, result.error.presence || "未能解析该链接")
        end
      rescue StandardError => e
        Rails.logger.warn("Wechat URL import failed for item ##{item.id}: #{e.class}: #{e.message}")
        task.record_failed!(item, e.message)
      end
    end

    task.finish! unless task.reload.completed? || task.failed?
  rescue ActiveRecord::RecordNotFound
    Rails.logger.warn("Wechat URL import task ##{task_id} was not found")
  end
end
