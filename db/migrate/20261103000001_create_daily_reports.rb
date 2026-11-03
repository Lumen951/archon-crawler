class CreateDailyReports < ActiveRecord::Migration[8.1]
  def change
    create_table :daily_reports do |t|
      t.date :report_date, null: false
      t.datetime :window_start, null: false
      t.datetime :window_end, null: false
      t.integer :status, null: false, default: 0
      t.integer :article_count, null: false, default: 0
      t.integer :paper_count, null: false, default: 0
      t.jsonb :sections, null: false, default: {}
      t.text :error_message
      t.timestamps
    end

    add_index :daily_reports, :report_date, unique: true
    add_index :daily_reports, :status
  end
end
