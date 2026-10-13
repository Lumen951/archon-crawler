class CreateEventResearchTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :event_research_tasks do |t|
      t.integer :status, null: false, default: 0
      t.integer :source, null: false, default: 0
      t.integer :account_concurrency
      t.boolean :refresh_cache, null: false, default: false
      t.integer :total, null: false, default: 0
      t.integer :progress, null: false, default: 0
      t.integer :error_count, null: false, default: 0
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at
      t.string :schedule_key
      t.timestamps
    end

    add_index :event_research_tasks, :status
    add_index :event_research_tasks, [ :source, :schedule_key ], unique: true,
      where: "source = 3 AND schedule_key IS NOT NULL", name: "idx_event_research_tasks_scheduled_key"

    create_table :event_research_task_accounts do |t|
      t.references :event_research_task, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.references :event_research_run, foreign_key: true
      t.integer :status, null: false, default: 0
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :event_research_task_accounts, [ :event_research_task_id, :account_id ], unique: true,
      name: "idx_event_research_task_accounts_unique"
    add_index :event_research_task_accounts, [ :event_research_task_id, :status ],
      name: "idx_event_research_task_accounts_status"
  end
end
