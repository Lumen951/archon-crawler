class RenameScreenNameToTwitterScreenName < ActiveRecord::Migration[8.1]
  def change
    rename_column :accounts, :screen_name, :twitter_screen_name
  end
end
