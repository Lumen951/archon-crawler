class AddRawDataToArticles < ActiveRecord::Migration[8.1]
  def change
    add_column :articles, :raw_data, :json
  end
end
