# == Schema Information
#
# Table name: event_research_tasks
#
#  id                  :bigint           not null, primary key
#  account_concurrency :integer
#  completed_at        :datetime
#  error_count         :integer          default(0), not null
#  error_message       :text
#  progress            :integer          default(0), not null
#  refresh_cache       :boolean          default(FALSE), not null
#  schedule_key        :string
#  source              :integer          default(0), not null
#  started_at          :datetime
#  status              :integer          default(0), not null
#  total               :integer          default(0), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
# Indexes
#
#  idx_event_research_tasks_scheduled_key  (source,schedule_key) UNIQUE WHERE ((source = 3) AND (schedule_key IS NOT NULL))
#  index_event_research_tasks_on_status    (status)
#
class EventResearchTask < ApplicationRecord
  has_many :event_research_task_accounts, dependent: :destroy
  has_many :accounts, through: :event_research_task_accounts
  has_many :crawl_logs, as: :loggable, dependent: :destroy
  has_one :event_weekly_digest, dependent: :destroy

  enum :status, { pending: 0, running: 1, paused: 2, completed: 3, failed: 4 }
  enum :source, { manual_single: 0, manual_selected: 1, manual_all: 2, scheduled: 3 }

  scope :recent, -> { order(created_at: :desc) }
  scope :terminal, -> { where(status: [ :completed, :failed ]) }

  def self.create_for!(accounts, source:, refresh_cache: false, schedule_key: nil)
    account_ids = accounts.pluck(:id).uniq
    raise ArgumentError, "请选择至少一个活动" if account_ids.empty?

    transaction do
      task = create!(source: source, refresh_cache: refresh_cache, schedule_key: schedule_key, total: account_ids.length)
      task.event_research_task_accounts.create!(account_ids.map { |account_id| { account_id: account_id } })
      task
    end
  end

  def effective_account_concurrency
    (account_concurrency.presence || Option.default_event_research_account_concurrency).to_i.clamp(1, 10)
  end

  def mark_running!
    with_lock do
      return false unless pending?

      update!(status: :running, started_at: Time.current, error_message: nil)
    end
    true
  end

  def pause!
    update!(status: :paused) if running?
  end

  def resume!
    return false unless paused? || failed?

    transaction do
      event_research_task_accounts.where(status: [ :failed, :running ]).update_all(status: :pending, error_message: nil, started_at: nil, completed_at: nil)
      update!(status: :pending, error_message: nil, completed_at: nil)
    end
    EventResearchTaskJob.perform_later(id)
  end

  def mark_failed!(message)
    log(:error, "研究任务失败：#{message}", force: true)
    update!(status: :failed, error_message: message.to_s.truncate(2000), completed_at: Time.current)
  end

  def finalize!
    reload
    return unless running?
    return if event_research_task_accounts.where(status: [ :pending, :running ]).exists?

    if failed_account_count.positive?
      update!(status: :failed, error_message: "#{failed_account_count} 个活动调研失败", completed_at: Time.current)
    else
      update!(status: :completed, completed_at: Time.current)
    end
    log(:info, "研究任务完成：完成 #{completed_account_count} 个，失败 #{failed_account_count} 个，跳过 #{skipped_account_count} 个", force: true)
  end

  def increment_progress!
    increment!(:progress)
  end

  def completed_account_count
    event_research_task_accounts.completed.count
  end

  def failed_account_count
    event_research_task_accounts.failed.count
  end

  def skipped_account_count
    event_research_task_accounts.skipped.count
  end

  def progress_percentage
    return 0 if total.zero?

    ((progress.to_f / total) * 100).round(1)
  end

  def api_usage(items = event_research_task_accounts.includes(:event_research_run))
    usage = {
      "search" => { "api_calls" => 0, "cache_hits" => 0 },
      "tianyancha" => { "api_calls" => 0, "cache_hits" => 0 }
    }

    items.each do |item|
      result = item.event_research_run&.result
      next unless result.is_a?(Hash)

      metadata = result["metadata"]
      next unless metadata.is_a?(Hash)

      cache = metadata["cache"]
      search_cache = cache.is_a?(Hash) ? cache["search"] : nil
      tianyancha_cache = cache.is_a?(Hash) ? cache["tianyancha"] : nil
      companies = metadata["companies"]

      usage["search"]["api_calls"] += search_cache.is_a?(Hash) ? search_cache["miss"].to_i : 0
      usage["search"]["cache_hits"] += search_cache.is_a?(Hash) ? search_cache["hit"].to_i : 0
      usage["tianyancha"]["api_calls"] += companies.is_a?(Hash) ? companies["api_calls"].to_i : 0
      usage["tianyancha"]["cache_hits"] += tianyancha_cache.is_a?(Hash) ? tianyancha_cache["hit"].to_i : 0
    end

    usage
  end

  def log(level, message, context: nil, force: false)
    CrawlLog.log(self, level, message, context: context, force: force)
  end
end
