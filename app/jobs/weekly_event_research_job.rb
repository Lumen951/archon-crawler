class WeeklyEventResearchJob < ApplicationJob
  queue_as :default

  def perform
    # 停用（inactive）的活动账号暂停每周自动调研；控制台手动调研不受影响
    EventAccount.weekly_research_enabled.active.find_each do |account|
      EventResearchRun.start_for!(account, refresh_cache: true)
    rescue EventResearchRun::ConcurrentRunError => e
      Rails.logger.info("[WeeklyEventResearchJob] 跳过 #{account.nickname}: #{e.message}")
    rescue StandardError => e
      Rails.logger.error("[WeeklyEventResearchJob] #{account.nickname} 失败: #{e.class}: #{e.message}")
    end
  end
end
