class CreateOptions < ActiveRecord::Migration[8.1]
  def change
    create_table :options do |t|
      t.string :opt_key, null: false
      t.string :opt_value

      t.timestamps
    end
    add_index :options, :opt_key, unique: true
  end
end
