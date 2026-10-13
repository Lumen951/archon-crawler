require "async"
require "async/semaphore"

class EventResearchTaskOrchestrator
  def self.run(task)
    return unless task.mark_running!

    task.log(:info, "开始研究任务，共 #{task.total} 个活动，并发 #{task.effective_account_concurrency}", force: true)

    Async do
      semaphore = Async::Semaphore.new(task.effective_account_concurrency)
      barrier = Async::Barrier.new

      task.event_research_task_accounts.pending.includes(:account).find_each do |item|
        break if task.reload.paused? || task.failed?

        barrier.async do
          semaphore.acquire do
            process_item(item, task) unless task.reload.paused? || task.failed?
          end
        end
      end

      barrier.wait
    end

    task.finalize!
    EventWeeklyDigestJob.perform_later(task.id, auto_send: task.scheduled?) if task.reload.completed? || task.failed?
  rescue StandardError => e
    task.mark_failed!("#{e.class}: #{e.message}")
    EventWeeklyDigestJob.perform_later(task.id, auto_send: task.scheduled?)
    Rails.logger.error("EventResearchTask##{task.id} 失败：#{e.message}\n#{e.backtrace.join("\n")}")
  end

  def self.process_item(item, task)
    item.with_lock do
      return unless item.pending?
      item.mark_running!
    end

    run = EventResearchRun.start_for!(item.account, refresh_cache: task.refresh_cache, enqueue: false)
    item.update!(event_research_run: run)
    EventResearchJob.execute_run(run)
    run.reload

    run.completed? ? item.mark_completed! : item.mark_failed!(run.error_message)
  rescue EventResearchRun::ConcurrentRunError => e
    item.mark_skipped!(e.message)
    task.log(:warn, "跳过 #{item.account.nickname}：#{e.message}", force: true)
  rescue StandardError => e
    item.mark_failed!("#{e.class}: #{e.message}")
    task.log(:error, "#{item.account.nickname} 调研失败：#{e.message}", force: true)
  ensure
    task.increment_progress! if item.reload.completed? || item.failed? || item.skipped?
  end
end
