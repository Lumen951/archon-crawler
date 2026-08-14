class AddNextCrawlAtToAccounts < ActiveRecord::Migration[8.1]
  def up
    add_column :accounts, :next_crawl_at, :datetime
    add_index :accounts, [:status, :next_crawl_at],
      name: "index_accounts_on_status_and_next_crawl_at"

    # Backfill: schedule each already-crawled account from its last crawl and
    # activity tier. Never-crawled accounts stay NULL (due immediately).
    Account.reset_column_information
    Account.where.not(last_crawled_at: nil).find_each do |account|
      account.update_column(:next_crawl_at, account.compute_next_crawl_at)
    end
  end

  def down
    remove_column :accounts, :next_crawl_at
  end
end
