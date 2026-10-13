# == Schema Information
#
# Table name: event_weekly_digests
#
#  id                     :bigint           not null, primary key
#  error_message          :text
#  payload_text           :text
#  sections               :jsonb            not null
#  sent_at                :datetime
#  status                 :integer          default(0), not null
#  week_start             :date             not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  event_research_task_id :bigint
#
# Indexes
#
#  index_event_weekly_digests_on_event_research_task_id  (event_research_task_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (event_research_task_id => event_research_tasks.id)
#
# 每个活动研究任务的一份聚合报告。表名保留以兼容已有在途数据；报告的范围以
# event_research_task 的成员快照及其关联 run 为准，不再以一周内所有运行聚合。
class EventWeeklyDigest < ApplicationRecord
  belongs_to :event_research_task, optional: true

  enum :status, { pending: 0, sent: 1, failed: 2, skipped: 3 }

  scope :recent, -> { order(created_at: :desc) }

  def self.for_task(task)
    find_or_initialize_by(event_research_task: task) do |report|
      report.week_start = task.created_at.to_date.beginning_of_week
    end
  end

  def self.feishu_target
    return unless Option.event_feishu_receive_id.present?

    { receive_id: Option.event_feishu_receive_id, receive_id_type: Option.event_feishu_receive_id_type.presence || "chat_id" }
  end

  def new_people_count
    count_from_summary("people") || Array(sections_hash["events"]).sum { |event| Array(event["new_people"]).length }
  end

  def projects_count
    count_from_summary("projects") || Array(sections_hash["events"]).sum { |event| event["projects_total"].to_i }
  end

  def contacts_count
    count_from_summary("contacts") || Array(sections_hash["events"]).sum { |event| event["contacts_total"].to_i }
  end

  def covered_events_count
    count_from_summary("events") || Array(sections_hash["events"]).length
  end

  def title
    "活动研究报告 ##{event_research_task_id || id}"
  end

  def period_label
    return event_research_task.created_at.strftime("%Y-%m-%d") if event_research_task

    week_start.strftime("%Y-%m-%d")
  end

  private

  def sections_hash
    sections.is_a?(Hash) ? sections : {}
  end

  def count_from_summary(key)
    summary = sections_hash["summary"]
    return unless summary.is_a?(Hash) && summary.key?(key)

    summary[key].to_i
  end
end
