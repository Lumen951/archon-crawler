class CreatePaperAuthorTracking < ActiveRecord::Migration[8.1]
  def change
    create_table :paper_subscriptions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :paper_author, null: false, foreign_key: true
      t.references :seed_paper, null: false, foreign_key: { to_table: :papers }
      t.string :display_name, null: false
      t.json :name_variants, null: false, default: []
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
    add_index :paper_subscriptions, [ :user_id, :paper_author_id ], unique: true

    create_table :paper_sync_runs do |t|
      t.references :paper_subscription, null: false, foreign_key: true
      t.string :status, null: false, default: "queued"
      t.string :run_token, null: false
      t.json :name_variants, null: false, default: []
      t.datetime :cutoff_at, null: false
      t.integer :next_offset, null: false, default: 0
      t.integer :total_count
      t.integer :page_count, null: false, default: 0
      t.datetime :retry_at
      t.datetime :completed_at
      t.text :error_message
      t.timestamps
    end

    create_table :paper_subscription_matches do |t|
      t.references :paper_subscription, null: false, foreign_key: true
      t.references :paper_source, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.json :evidence, null: false, default: {}
      t.datetime :reviewed_at
      t.timestamps
    end
    add_index :paper_subscription_matches, [ :paper_subscription_id, :paper_source_id ],
      unique: true, name: "index_paper_matches_on_subscription_source"
  end
end
