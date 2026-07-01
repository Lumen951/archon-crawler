class CreateAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.string :fakeid, null: false
      t.string :nickname, null: false
      t.string :round_head_img
      t.integer :status, default: 0
      t.integer :total_articles, default: 0
      t.datetime :last_crawled_at

      t.timestamps
    end
    add_index :accounts, :fakeid, unique: true
    add_index :accounts, :status
  end
end
