class CreateTagAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :tag_accounts do |t|
      t.references :tag, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.timestamps
    end

    add_index :tag_accounts, [:tag_id, :account_id], unique: true
  end
end
