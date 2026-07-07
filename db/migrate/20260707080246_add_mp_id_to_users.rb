class AddMpIdToUsers < ActiveRecord::Migration[8.1]
  def up
    change_column :users, :password_digest, :string, null: true
    add_column :users, :mp_id, :string
    add_index :users, :mp_id, unique: true
  end

  def down
    remove_index :users, :mp_id
    remove_column :users, :mp_id
    change_column :users, :password_digest, :string, null: false
  end
end
