class EventWeeklyDigestJob < ApplicationJob
  queue_as :default

  def perform(task_id, auto_send: false)
    task = EventResearchTask.find_by(id: task_id)
    return unless task && (task.completed? || task.failed?)

    report = EventWeeklyDigest.for_task(task)
    report.sections = EventResearch::WeeklyDigestBuilder.call(task)
    report.status = :pending
    report.error_message = nil
    report.sent_at = nil
    report.save!

    report.update!(payload_text: EventResearch::WeeklyDigestText.call(report))
    return report.update!(status: :skipped, error_message: "手动研究任务仅生成站内报告") unless auto_send

    send_to_feishu(report)
  rescue FeishuNotifier::Error, Faraday::Error => e
    report&.update(status: :failed, error_message: e.message.to_s.truncate(2000))
    Rails.logger.error("[EventWeeklyDigestJob] 研究报告发送失败: #{e.message}")
  end

  private

  def send_to_feishu(report)
    target = EventWeeklyDigest.feishu_target
    unless target
      report.update!(status: :skipped, error_message: "未配置活动调研飞书推送目标（管理设置 → 飞书推送）")
      return
    end

    FeishuNotifier.send_text(report.payload_text, **target)
    report.update!(status: :sent, sent_at: Time.current, error_message: nil)
  end
end
