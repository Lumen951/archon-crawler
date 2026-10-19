class CreatePaperTracking < ActiveRecord::Migration[8.1]
  def change
    create_table :papers do |t|
      t.string :title, null: false
      t.text :abstract
      t.datetime :published_at
      t.datetime :updated_at_source
      t.timestamps
    end

    create_table :paper_sources do |t|
      t.references :paper, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :external_id, null: false
      t.string :canonical_url, null: false
      t.json :raw_metadata, null: false, default: {}
      t.datetime :last_seen_at
      t.timestamps
    end
    add_index :paper_sources, [ :provider, :external_id ], unique: true

    create_table :paper_authors do |t|
      t.string :display_name, null: false
      t.string :provider
      t.string :external_id
      t.string :normalized_name, null: false
      t.timestamps
    end
    add_index :paper_authors, [ :provider, :external_id ]
    add_index :paper_authors, :normalized_name

    create_table :paper_authorships do |t|
      t.references :paper, null: false, foreign_key: true
      t.references :paper_author, null: false, foreign_key: true
      t.integer :position, null: false
      t.string :display_name, null: false
      t.timestamps
    end
    add_index :paper_authorships, [ :paper_id, :position ], unique: true

    create_table :paper_import_tasks do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :status, null: false, default: 0
      t.integer :total_count, null: false, default: 0
      t.integer :processed_count, null: false, default: 0
      t.integer :imported_count, null: false, default: 0
      t.integer :failed_count, null: false, default: 0
      t.datetime :started_at
      t.datetime :completed_at
      t.text :error_message
      t.timestamps
    end
    add_index :paper_import_tasks, :status

    create_table :paper_import_items do |t|
      t.references :paper_import_task, null: false, foreign_key: true
      t.references :paper, foreign_key: true
      t.string :url, null: false
      t.string :provider
      t.integer :status, null: false, default: 0
      t.text :error_message
      t.datetime :processed_at
      t.timestamps
    end
    add_index :paper_import_items, [ :paper_import_task_id, :url ], unique: true
    add_index :paper_import_items, :status
  end
end
