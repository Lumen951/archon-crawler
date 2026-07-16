class CreateApiKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :api_keys do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :token_digest, null: false
      t.boolean :active, default: true
      t.integer :rate_limit, default: 100

      t.timestamps
    end

    add_index :api_keys, :token_digest, unique: true
  end
end
