class PaperSubscriptionMatch < ApplicationRecord
  belongs_to :paper_subscription
  belongs_to :paper_source

  enum :status, { pending: "pending", confirmed: "confirmed", excluded: "excluded" }

  def review!(decision)
    raise ArgumentError unless %w[confirmed excluded pending].include?(decision)

    with_lock { update!(status: decision, reviewed_at: Time.current) }
    return unless confirmed?

    paper_source.prepare_full_text!&.enqueue!
  end

  def status_label
    { "pending" => "待确认", "confirmed" => "已确认", "excluded" => "已排除" }.fetch(status)
  end
end
