class AddActivityCountersToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :last_published_at, :datetime
    add_column :accounts, :articles_count, :integer, default: 0, null: false
    add_column :accounts, :articles_last_7_days, :integer, default: 0, null: false
    add_column :accounts, :articles_last_30_days, :integer, default: 0, null: false
    add_column :accounts, :activity_score, :integer, default: 0, null: false

    add_index :accounts, [:status, :last_published_at],
      name: "index_accounts_on_status_and_last_published_at"
  end
end
