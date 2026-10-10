class EventResearchNotificationJob < ApplicationJob
  queue_as :default

  def perform(run_id, notification_id: nil, force: false)
    run = EventResearchRun.find_by(id: run_id)
    return unless run&.completed?

    account = run.account
    notification = notification_id ? account.event_research_notifications.find_by(id: notification_id) : nil
    kind = notification&.kind || (EventResearchNotification.last_sent_for(account, kind: :initial).nil? ? :initial : :weekly)
    notification ||= EventResearchNotification.find_or_create_by!(event_research_run: run, kind: kind) do |record|
      record.account = account
    end
    return if !force && (notification.sent? || notification.skipped?)

    baseline = notification.weekly? ? (notification.baseline_run || EventResearchNotification.last_sent_baseline_for(account)) : nil
    text = notification.payload_text.presence
    if text.blank?
      diff = baseline ? EventResearch::ResultDiff.call(baseline.event_research_run.result, run.result) : nil
      text = baseline ? EventResearch::NotificationSummary.weekly(account, run, diff) : EventResearch::NotificationSummary.initial(account, run)
    end

    if text.blank?
      notification.update!(status: :skipped, baseline_run: baseline&.event_research_run)
      return
    end

    notification.update!(
      status: :pending,
      baseline_run: baseline&.event_research_run,
      payload_text: text,
      payload_digest: Digest::SHA256.hexdigest(text),
      sent_at: nil,
      error_message: nil
    )

    target = account.feishu_target
    unless target.present? && (FeishuNotifier.enabled? || FeishuNotifier.credentials_enabled?)
      notification.update!(status: :skipped, error_message: "飞书推送未配置")
      Rails.logger.info("[EventResearchNotificationJob] 飞书未配置，跳过 run##{run.id}")
      return
    end

    FeishuNotifier.send_text(text, **target)
    notification.update!(status: :sent, sent_at: Time.current, error_message: nil)
  rescue ActiveRecord::RecordNotUnique
    retry
  rescue FeishuNotifier::Error, Faraday::Error => e
    notification&.update(status: :failed, error_message: e.message.to_s.truncate(2000))
    Rails.logger.error("[EventResearchNotificationJob] run##{run_id} 发送失败: #{e.message}")
  end
end
