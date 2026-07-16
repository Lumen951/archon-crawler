class CreateGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :groups do |t|
      t.references :user, null: false, foreign_key: true
      t.string :ref_key, null: false
      t.string :name

      t.timestamps
    end

    add_index :groups, [:user_id, :ref_key], unique: true
  end
end
