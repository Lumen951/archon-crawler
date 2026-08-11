class RefreshActivityCountersJob < ApplicationJob
  queue_as :low

  def perform
    total = Account.count
    processed = 0
    Rails.logger.info "[RefreshActivityCountersJob] Starting refresh for #{total} accounts"

    Account.find_each do |account|
      account.refresh_activity_counters!
      processed += 1
    end

    Rails.logger.info "[RefreshActivityCountersJob] Refreshed #{processed} accounts"

    # Reschedule for next week
    self.class.set(wait: 7.days).perform_later
  rescue StandardError => e
    Rails.logger.error "[RefreshActivityCountersJob] Error: #{e.message}"
    # Still reschedule even on error so the job doesn't die permanently
    self.class.set(wait: 7.days).perform_later
    raise
  end
end
