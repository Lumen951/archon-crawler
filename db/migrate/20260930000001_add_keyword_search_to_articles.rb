class AddKeywordSearchToArticles < ActiveRecord::Migration[8.1]
  def up
    enable_extension "pg_trgm"

    add_index :articles, :title, using: :gin, opclass: :gin_trgm_ops,
              name: "index_articles_on_title_trgm"
    add_index :articles, :digest, using: :gin, opclass: :gin_trgm_ops,
              name: "index_articles_on_digest_trgm"
    # No index on the body (content_markdown / content_html): at ~200k articles
    # those columns hold gigabytes of text, so a trgm GIN index over them would
    # be as large as the data itself, take hours to build and slow every insert.
    # search_keyword only matches title and digest, which keeps the OR below
    # fully indexable — a non-indexed branch would force a seq scan and make
    # both indexes above dead weight.
  end

  def down
    remove_index :articles, name: "index_articles_on_digest_trgm"
    remove_index :articles, name: "index_articles_on_title_trgm"
    # pg_trgm itself is left installed; dropping it could break other users of the database.
  end
end
