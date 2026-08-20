class CreateDeviceCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :device_codes do |t|
      t.string :device_code, null: false
      t.string :user_code, null: false
      t.string :client_id, null: false
      t.string :scope
      t.references :user, foreign_key: true
      t.integer :status, default: 0, null: false  # pending: 0, authorized: 1, expired: 2, denied: 3
      t.datetime :expires_at, null: false
      t.integer :interval, default: 5, null: false
      t.string :ip_address
      t.timestamps
    end

    add_index :device_codes, :device_code, unique: true
    add_index :device_codes, :user_code, unique: true
    add_index :device_codes, :expires_at
  end
end
