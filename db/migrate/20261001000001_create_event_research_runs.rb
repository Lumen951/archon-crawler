class CreateEventResearchRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :event_research_runs do |t|
      t.references :account, null: false, foreign_key: { to_table: :accounts }
      t.integer :status, default: 0, null: false
      t.jsonb :result
      t.integer :people_count
      t.integer :award_count
      t.integer :company_count
      t.boolean :refresh_cache, default: false, null: false
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :event_research_runs, :status
    add_index :event_research_runs, [ :account_id, :created_at ]
    # 同一账号同时只允许一个进行中的调研（pending/running），数据库层兜底，
    # 避免两轮调研并发打同一批外部 API。
    add_index :event_research_runs, :account_id,
              unique: true,
              where: "status IN (0, 1)",
              name: "index_event_research_runs_on_account_id_active"
  end
end
