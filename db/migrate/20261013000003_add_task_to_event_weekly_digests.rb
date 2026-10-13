class AddTaskToEventWeeklyDigests < ActiveRecord::Migration[8.1]
  def change
    remove_index :event_weekly_digests, :week_start
    add_reference :event_weekly_digests, :event_research_task, foreign_key: true, index: { unique: true }
  end
end
