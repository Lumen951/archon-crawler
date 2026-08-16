class CreateWechatContentDownloadTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :wechat_content_download_tasks do |t|
      t.string :job_id, null: false
      t.integer :status, default: 0, null: false
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :heartbeat_at, null: false
      t.integer :articles_total, default: 0, null: false
      t.integer :articles_downloaded, default: 0, null: false
      t.integer :articles_failed, default: 0, null: false
      t.text :error_message

      t.timestamps
    end

    add_index :wechat_content_download_tasks, :job_id, unique: true
  end
end
