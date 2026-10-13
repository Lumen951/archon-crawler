class WeeklyEventResearchJob < ApplicationJob
  queue_as :default

  def perform
    accounts = EventAccount.weekly_research_enabled.active
    return if accounts.empty?

    schedule_key = Date.current.beginning_of_week.iso8601
    task = EventResearchTask.create_for!(
      accounts,
      source: :scheduled,
      refresh_cache: true,
      schedule_key: schedule_key
    )
    EventResearchTaskJob.perform_later(task.id)
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info("[WeeklyEventResearchJob] 本周定时研究任务已存在，跳过重复投递")
  end
end
