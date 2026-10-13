class EventResearchTaskJob < ApplicationJob
  queue_as :default

  def perform(task_id)
    task = EventResearchTask.find_by(id: task_id)
    return unless task
    return if task.completed? || task.failed? || task.paused?

    EventResearchTaskOrchestrator.run(task)
  end
end
