# 重发已生成的研究报告：不重新生成内容，只把保存的 payload_text 再推一次。
# 管理员在报告详情页点「重新推送」时投递。
class EventWeeklyDigestResendJob < ApplicationJob
  queue_as :default

  def perform(digest_id)
    digest = EventWeeklyDigest.find_by(id: digest_id)
    return unless digest&.payload_text.present?

    target = EventWeeklyDigest.feishu_target
    if target.blank?
      digest.update!(status: :skipped, error_message: "未配置活动调研飞书推送目标（管理设置 → 飞书推送）")
      return
    end

    FeishuNotifier.send_text(digest.payload_text, **target)
    digest.update!(status: :sent, sent_at: Time.current, error_message: nil)
  rescue FeishuNotifier::Error, Faraday::Error => e
    digest&.update(status: :failed, error_message: e.message.to_s.truncate(2000))
    Rails.logger.error("[EventWeeklyDigestResendJob] 研究报告重发失败: #{e.message}")
  end
end
