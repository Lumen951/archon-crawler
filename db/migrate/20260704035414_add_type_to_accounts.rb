class AddTypeToAccounts < ActiveRecord::Migration[8.1]
  def up
    add_column :accounts, :type, :string
    add_index :accounts, :type
    # Set all existing accounts as WechatAccount
    execute "UPDATE accounts SET type = 'WechatAccount'"
    change_column_null :accounts, :type, false
  end

  def down
    remove_index :accounts, :type
    remove_column :accounts, :type
  end
end
