class CreateGroupAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :group_accounts do |t|
      t.references :group, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true

      t.timestamps
    end

    add_index :group_accounts, [:group_id, :account_id], unique: true
  end
end
