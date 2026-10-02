# == Schema Information
#
# Table name: event_research_runs
#
#  id            :bigint           not null, primary key
#  award_count   :integer
#  company_count :integer
#  completed_at  :datetime
#  error_message :text
#  people_count  :integer
#  refresh_cache :boolean          default(FALSE), not null
#  result        :jsonb
#  started_at    :datetime
#  status        :integer          default(0), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  account_id    :bigint           not null
#
# Indexes
#
#  index_event_research_runs_on_account_id                 (account_id)
#  index_event_research_runs_on_account_id_active          (account_id) UNIQUE WHERE (status = ANY (ARRAY[0, 1]))
#  index_event_research_runs_on_account_id_and_created_at  (account_id,created_at)
#  index_event_research_runs_on_status                     (status)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
# 一次活动调研的运行记录。结果 JSON（{"event", "awards", "companies", "metadata"}）
# 原样存进 result —— 数据是调研的第一产物，报告由使用者基于这份数据自行生成。
# 过程日志在多态 CrawlLog（loggable = 本模型），与抓取日志共用存储但互不相干。
class EventResearchRun < ApplicationRecord
  belongs_to :account

  # 调研过程日志（与抓取任务共用多态 CrawlLog 存储）
  has_many :crawl_logs, as: :loggable, dependent: :destroy

  enum :status, { pending: 0, running: 1, completed: 2, failed: 3 }

  scope :recent, -> { order(created_at: :desc) }
  scope :active, -> { where(status: [ :pending, :running ]) }

  # 同一账号已有进行中的调研时启动新调研会抛出它
  class ConcurrentRunError < StandardError; end

  class << self
    # 创建一行新调研并投递 job。唯一的部分索引（account_id WHERE status IN (0,1)）
    # 在数据库层兜底并发点击；RecordNotUnique 也归一成 ConcurrentRunError。
    def start_for!(account, refresh_cache: false)
      if account.event_research_runs.active.exists?
        raise ConcurrentRunError, "该活动已有进行中的调研，请等它结束后再重新启动"
      end

      create!(account: account, status: :pending, refresh_cache: refresh_cache).tap do |run|
        EventResearchJob.perform_later(run.id)
      end
    rescue ActiveRecord::RecordNotUnique
      raise ConcurrentRunError, "该活动已有进行中的调研，请等它结束后再重新启动"
    end

    # 账号最近一次成功完成的调研（API/MCP「取最新数据」用）
    def latest_completed_for(account)
      account.event_research_runs.completed.recent.first
    end
  end

  # 进入 running。只有 pending 能转 running（重复/并发投递时后续调用直接返回 false），
  # 这样 EventResearchJob 天然幂等：同一轮调研不会被跑两次。
  def mark_running!
    with_lock do
      return false unless pending?

      update!(status: :running, started_at: Time.current, error_message: nil)
    end
    true
  end

  # 存调研结果。退化结果（没抽到任何获奖/人物）也如实保留数据供检查，
  # 但状态标 failed —— 对外它不是一次成功的研究。
  def store_result!(result)
    result = result.is_a?(Hash) ? result : {}
    degenerate = EventResearch.degenerate_result?(result)

    update!(
      result: result,
      status: degenerate ? :failed : :completed,
      completed_at: Time.current,
      people_count: people_found_count(result),
      award_count: result["awards"].to_a.length,
      company_count: result["companies"].to_a.length,
      error_message: degenerate ? "调研跑完了但没有提取到有效数据（获奖名单和人物均为空），请检查运行日志后重试" : nil
    )
  end

  def mark_failed!(message)
    update_columns(
      status: self.class.statuses[:failed],
      error_message: message.to_s.truncate(2000),
      completed_at: Time.current
    )
  end

  def duration_seconds
    return nil unless started_at && completed_at

    (completed_at - started_at).round
  end

  def status_badge_class
    case status
    when "pending" then "bg-gray-100 text-gray-700"
    when "running" then "bg-blue-100 text-blue-700"
    when "completed" then "bg-green-100 text-green-700"
    when "failed" then "bg-red-100 text-red-700"
    else "bg-gray-100 text-gray-700"
    end
  end

  private

  def people_found_count(result)
    found = result.dig("metadata", "people_found")
    return found.to_i if found

    result["awards"].to_a
                    .flat_map { |award| award["people"].to_a }
                    .select { |person| person.is_a?(Hash) && person["name"].present? }
                    .uniq { |person| person["name"] }
                    .length
  end
end
