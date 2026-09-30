class AddKeywordSearchToArticles < ActiveRecord::Migration[8.1]
  def up
    enable_extension "pg_trgm"

    add_index :articles, :title, using: :gin, opclass: :gin_trgm_ops,
              name: "index_articles_on_title_trgm"
    add_index :articles, :digest, using: :gin, opclass: :gin_trgm_ops,
              name: "index_articles_on_digest_trgm"
    # Article.search_keyword searches the body via this exact expression, which
    # lets the planner use the index for COALESCE(content_markdown, content_html).
    # The opclass is embedded in the expression because ActiveRecord does not
    # apply the `opclass:` option to raw SQL string columns.
    add_index :articles, "COALESCE(content_markdown, content_html) gin_trgm_ops", using: :gin,
              name: "index_articles_on_body_trgm"
  end

  def down
    remove_index :articles, name: "index_articles_on_body_trgm"
    remove_index :articles, name: "index_articles_on_digest_trgm"
    remove_index :articles, name: "index_articles_on_title_trgm"
    # pg_trgm itself is left installed; dropping it could break other users of the database.
  end
end
