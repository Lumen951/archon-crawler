class AddContentMarkdownTrgmIndexToArticles < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Lets search_keyword match content_markdown: the body gets the same trgm
  # GIN index as title/digest, keeping the ILIKE OR fully indexable. Only
  # content_markdown is indexed — content_html is markup noise and was part of
  # the earlier body-index attempt whose plain CREATE INDEX blocked article
  # writes and took the RDS instance down; do not repeat that here.
  #
  # This build is safe to run against production: CONCURRENTLY never blocks
  # reads or writes, and if it is interrupted, re-running this migration drops
  # the INVALID leftover and starts a clean rebuild. Deploy in a low-traffic
  # window: the build still saturates disk I/O for its duration and the index
  # ends up roughly as large as the column itself. Search terms shorter than
  # three characters cannot form a trigram, so those queries fall back to a
  # scan (as they already do for title/digest today).
  def up
    execute "DROP INDEX CONCURRENTLY IF EXISTS index_articles_on_content_markdown_trgm"
    execute "SET maintenance_work_mem = '128MB'"

    add_index :articles, :content_markdown, using: :gin, opclass: :gin_trgm_ops,
              name: "index_articles_on_content_markdown_trgm", algorithm: :concurrently
  end

  def down
    remove_index :articles, name: "index_articles_on_content_markdown_trgm"
  end
end
