class AddScreenNameToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :screen_name, :string
    add_index :accounts, :screen_name
  end
end
