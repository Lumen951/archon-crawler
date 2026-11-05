class AddMarkdownContentToDailyReports < ActiveRecord::Migration[8.1]
  def change
    add_column :daily_reports, :markdown_content, :text
  end
end
