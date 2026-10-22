class CreatePaperFullTexts < ActiveRecord::Migration[8.1]
  def change
    create_table :paper_full_texts do |t|
      t.references :paper_source, null: false, foreign_key: true
      t.integer :version, null: false
      t.string :status, null: false, default: "pending"
      t.string :run_token
      t.text :error_message
      t.json :resources, null: false, default: {}
      t.datetime :downloaded_at
      t.datetime :retry_at
      t.timestamps
    end
    add_index :paper_full_texts, [ :paper_source_id, :version ], unique: true
  end
end
