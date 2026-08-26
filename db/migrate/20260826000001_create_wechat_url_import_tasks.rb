class CreateWechatUrlImportTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :wechat_url_import_tasks do |t|
      t.integer :status, null: false, default: 0
      t.integer :total_count, null: false, default: 0
      t.integer :processed_count, null: false, default: 0
      t.integer :created_count, null: false, default: 0
      t.integer :found_count, null: false, default: 0
      t.integer :failed_count, null: false, default: 0
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :wechat_url_import_tasks, :status

    create_table :wechat_url_import_items do |t|
      t.references :wechat_url_import_task, null: false, foreign_key: true
      t.references :account, foreign_key: true
      t.string :url, null: false
      t.integer :status, null: false, default: 0
      t.text :error_message
      t.datetime :started_at
      t.datetime :processed_at
      t.timestamps
    end

    add_index :wechat_url_import_items, [:wechat_url_import_task_id, :url], unique: true, name: "index_wechat_url_import_items_on_task_and_url"
    add_index :wechat_url_import_items, :status
  end
end
