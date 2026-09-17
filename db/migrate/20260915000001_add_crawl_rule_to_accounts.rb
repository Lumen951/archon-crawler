class AddCrawlRuleToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :crawl_rule, :jsonb, default: {}, null: false
  end
end
