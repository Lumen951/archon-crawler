class CreateTags < ActiveRecord::Migration[8.1]
  def change
    create_table :tags do |t|
      t.string :name, null: false
      t.string :name_normalized, null: false
      t.string :color, default: "#6366f1"
      t.text :description
      t.integer :position, default: 0
      t.integer :tag_accounts_count, default: 0
      t.timestamps
    end

    add_index :tags, :name_normalized, unique: true
    add_index :tags, :position
  end
end
