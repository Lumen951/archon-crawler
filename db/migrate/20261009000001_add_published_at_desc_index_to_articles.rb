class AddPublishedAtDescIndexToArticles < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Article.recent orders by `published_at DESC NULLS LAST`. The only index that
  # covers that column is `index_articles_on_published_at`, a plain btree
  # (ASC NULLS LAST): scanning it backward yields DESC NULLS FIRST, which does
  # not satisfy the query's ordering. The planner therefore had no index that
  # could produce rows in order and fell back to a sequential scan plus a top-N
  # sort over the whole table — confirmed on production with
  # `SET enable_seqscan = off`, which still chose a Seq Scan.
  #
  # Measured on production (177k articles, 3.7 GB table, 185 MB shared_buffers):
  #
  #   listing, no keyword        1414 ms  ->   14 ms
  #   keyword "人工智能" (21k hits)  18777 ms  ->  432 ms
  #   keyword "大学"     (82k hits)  26250 ms  ->   53 ms
  #
  # Rare terms are unaffected: the planner still picks bitmap index scans on the
  # trgm indexes (~1-11 ms) when the ordered scan would have to walk too far.
  #
  # NULLS LAST is load-bearing. Postgres defaults `DESC` to NULLS FIRST, and the
  # two orderings are not interchangeable for index matching.
  #
  # `if_not_exists` because this index was created manually (CONCURRENTLY) on
  # production before this migration shipped, so the first deploy after it must
  # be a no-op rather than an "index already exists" failure.
  def up
    add_index :articles, :published_at,
              order: { published_at: "DESC NULLS LAST" },
              name: "index_articles_on_published_at_desc_nulls_last",
              if_not_exists: true,
              algorithm: :concurrently
  end

  def down
    remove_index :articles,
                 name: "index_articles_on_published_at_desc_nulls_last",
                 algorithm: :concurrently
  end
end
