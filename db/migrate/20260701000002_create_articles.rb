class CreateArticles < ActiveRecord::Migration[8.1]
  def change
    create_table :articles do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.string :title, null: false
      t.string :url, null: false
      t.string :author
      t.text :digest
      t.string :cover_url
      t.text :content_markdown
      t.text :content_html
      t.datetime :published_at

      t.timestamps
    end
    add_index :articles, :url, unique: true
    add_index :articles, :published_at
  end
end
