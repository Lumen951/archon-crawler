class AddCrawlTaskToArticles < ActiveRecord::Migration[8.1]
  def change
    add_reference :articles, :crawl_task, null: true, foreign_key: true
  end
end
