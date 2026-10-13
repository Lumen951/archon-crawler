class CreateEventWeeklyDigests < ActiveRecord::Migration[8.1]
  def change
    create_table :event_weekly_digests do |t|
      t.date :week_start, null: false
      t.integer :status, default: 0, null: false
      t.text :payload_text
      t.jsonb :sections, default: {}, null: false
      t.datetime :sent_at
      t.text :error_message

      t.timestamps
    end

    add_index :event_weekly_digests, :week_start, unique: true
  end
end
