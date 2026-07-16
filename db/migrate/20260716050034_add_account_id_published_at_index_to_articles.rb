class AddAccountIdPublishedAtIndexToArticles < ActiveRecord::Migration[8.1]
  def change
    # Composite index covers queries that join on account_id and filter/sort
    # by published_at (e.g. Api::V1::ArticlesController#index). It also
    # serves lookups on account_id alone, so the old single-column index is
    # redundant and gets replaced.
    remove_index :articles, :account_id, if_exists: true
    add_index :articles, [:account_id, :published_at], order: { published_at: :desc }, name: "index_articles_on_account_id_and_published_at"
  end
end
