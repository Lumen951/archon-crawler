class DropEventResearchNotifications < ActiveRecord::Migration[8.1]
  def change
    drop_table :event_research_notifications do |t|
      t.references :account, null: false, foreign_key: true
      t.references :event_research_run, null: false, foreign_key: true
      t.references :baseline_run, foreign_key: { to_table: :event_research_runs }
      t.integer :kind, null: false, default: 0
      t.integer :status, null: false, default: 0
      t.string :payload_digest
      t.text :payload_text
      t.datetime :sent_at
      t.text :error_message

      t.timestamps

      t.index [ :event_research_run_id, :kind ], unique: true, name: "index_event_research_notifications_on_run_and_kind"
      t.index [ :account_id, :kind, :status ], name: "index_event_research_notifications_on_account_kind_status"
    end
  end
end
