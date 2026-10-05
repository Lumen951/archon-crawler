class AddKeywordSearchToArticles < ActiveRecord::Migration[8.1]
  def up
    enable_extension "pg_trgm"

    add_index :articles, :title, using: :gin, opclass: :gin_trgm_ops,
              name: "index_articles_on_title_trgm"
    add_index :articles, :digest, using: :gin, opclass: :gin_trgm_ops,
              name: "index_articles_on_digest_trgm"
    # No index on the body (content_markdown / content_html) in THIS migration:
    # at ~200k articles those columns hold gigabytes of text, so a trgm GIN
    # index over them would be as large as the data itself and take hours to
    # build. An earlier attempt indexed both body columns with a plain CREATE
    # INDEX on RDS; the build blocked article writes, saturated the instance
    # and was abandoned. search_keyword now also matches content_markdown,
    # backed by a CONCURRENTLY-built, retry-safe index added later in
    # 20261005000001. content_html remains deliberately unindexed and
    # unsearched.
  end

  def down
    remove_index :articles, name: "index_articles_on_digest_trgm"
    remove_index :articles, name: "index_articles_on_title_trgm"
    # pg_trgm itself is left installed; dropping it could break other users of the database.
  end
end
