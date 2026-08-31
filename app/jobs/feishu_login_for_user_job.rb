# 为单个飞书用户生成专属扫码登录二维码，私聊推送并轮询登录结果。
#
# 由 FeishuCallbacksController 在用户点击卡片按钮后入队，每个 open_id 各自一份
# 登录会话——微信读书借此形成多账号池；微信公众号平台只有一个会话槽位，
# 多人同时扫码时最后登录成功者胜出（都是合法会话，不会互相污染）。
require "digest"

class FeishuLoginForUserJob < ApplicationJob
  include QrLogin::Polling

  queue_as :default

  def perform(provider_key, open_id)
    started_at = monotonic_time
    context = log_context(provider_key, open_id, started_at)
    log(context, :info, "started")

    provider = QrLogin.find(provider_key)
    log(context, :info, "provider resolved label=#{provider.label.inspect}")

    log(context, :info, "qr creation begin")
    session = provider.start
    log(
      context,
      :info,
      "qr creation complete handle=#{handle_summary(session[:handle])} " \
      "image_mime=#{session[:image_mime].inspect} image_bytes=#{session[:image_bytes].to_s.bytesize}"
    )

    log(context, :info, "qr delivery begin")
    FeishuNotifier.send_qr_login_to(
      open_id: open_id,
      png_bytes: session[:image_bytes],
      text: "请用微信扫描上方二维码完成#{provider.label}登录，二维码约 2 分钟有效。"
    )
    log(context, :info, "qr delivery complete")

    result = poll_until_done(provider, session[:handle], log_context: ->(level, message) { log(context, level, message) })
    log(context, :info, "polling complete status=#{result[:status].inspect} elapsed_ms=#{elapsed_ms(started_at)}")

    log(context, :info, "final notification begin status=#{result[:status].inspect}")
    FeishuNotifier.send_text(result_text(provider, result), receive_id: open_id, receive_id_type: "open_id")
    log(context, :info, "final notification complete elapsed_ms=#{elapsed_ms(started_at)}")
  rescue FeishuNotifier::Error => e
    log(context, :error, "feishu error=#{e.class} message=#{safe_message(e.message)} elapsed_ms=#{elapsed_ms(started_at)}")
  rescue StandardError => e
    log(context, :error, "failed error=#{e.class} message=#{safe_message(e.message)} elapsed_ms=#{elapsed_ms(started_at)}")
  end

  private

  def log_context(provider_key, open_id, started_at)
    {
      job_id: job_id,
      provider_key: provider_key,
      recipient: Digest::SHA256.hexdigest(open_id.to_s)[0, 12],
      started_at: started_at
    }
  end

  def log(context, level, message)
    Rails.logger.public_send(level, "[FeishuLoginForUserJob] job_id=#{context[:job_id]} provider=#{context[:provider_key]} recipient_sha=#{context[:recipient]} #{message}")
  end

  def handle_summary(handle)
    return "none" unless handle.is_a?(Hash)

    keys = handle.keys.map(&:to_s).sort.join(",")
    uuid = handle["uuid"] || handle[:uuid]
    uuid_summary = uuid.present? ? "uuid_sha=#{Digest::SHA256.hexdigest(uuid.to_s)[0, 12]}" : "uuid=absent"
    "keys=#{keys.inspect} #{uuid_summary}"
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started_at)
    ((monotonic_time - started_at) * 1000).round
  end

  def safe_message(message)
    message.to_s.gsub(/[\r\n]+/, " ")[0, 200].inspect
  end

  def result_text(provider, result)
    case result[:status]
    when :success then provider.success_text(result[:identity])
    when :expired, :timeout then "⏰ #{provider.label}二维码已过期，请重新点击登录按钮获取新二维码"
    else "⚠️ #{provider.label}登录失败：#{result[:message].presence || '未知错误'}"
    end
  end
end
