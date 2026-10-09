require "test_helper"

# == Schema Information
#
# Table name: articles
#
#  id               :bigint           not null, primary key
#  author           :string
#  content_html     :text
#  content_markdown :text
#  cover_url        :string
#  digest           :text
#  published_at     :datetime
#  raw_data         :json
#  title            :string           not null
#  url              :string           not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  crawl_task_id    :bigint
#
# Indexes
#
#  index_articles_on_account_id_and_published_at   (account_id,published_at DESC)
#  index_articles_on_content_markdown_trgm         (content_markdown) USING gin
#  index_articles_on_crawl_task_id                 (crawl_task_id)
#  index_articles_on_digest_trgm                   (digest) USING gin
#  index_articles_on_published_at                  (published_at)
#  index_articles_on_published_at_desc_nulls_last  (published_at)
#  index_articles_on_title_trgm                    (title) USING gin
#  index_articles_on_url                           (url) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (crawl_task_id => crawl_tasks.id)
#
class ArticleTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:one)
    @in_title = @account.articles.create!(
      title: "微信公众号爬虫实战",
      url: "https://example.com/search-title-#{SecureRandom.hex(8)}",
      published_at: 1.day.ago
    )
    @in_digest = @account.articles.create!(
      title: "无关标题甲",
      url: "https://example.com/search-digest-#{SecureRandom.hex(8)}",
      digest: "本文介绍爬虫框架",
      published_at: 2.days.ago
    )
    @body_markdown_only = @account.articles.create!(
      title: "无关标题乙",
      url: "https://example.com/search-markdown-#{SecureRandom.hex(8)}",
      content_markdown: "正文里提到爬虫工具",
      published_at: 3.days.ago
    )
    @body_html_only = @account.articles.create!(
      title: "无关标题丙",
      url: "https://example.com/search-html-#{SecureRandom.hex(8)}",
      content_html: "<p>正文里提到爬虫框架</p>",
      published_at: 4.days.ago
    )
    @no_match = @account.articles.create!(
      title: "完全无关的文章",
      url: "https://example.com/search-none-#{SecureRandom.hex(8)}",
      published_at: 5.days.ago
    )
  end

  test "recent orders articles without a publication time last" do
    undated = @account.articles.create!(
      title: "Undated article",
      url: "https://example.com/undated-#{SecureRandom.hex(8)}"
    )

    assert_equal undated, Article.recent.to_a.last
  end

  test "search_keyword matches title and digest" do
    results = Article.search_keyword("爬虫")

    assert_includes results, @in_title
    assert_includes results, @in_digest
    assert_not_includes results, @no_match
  end

  # The body search targets content_markdown only: content_html is the raw
  # presentation source, markdown is the canonical searchable text.
  test "search_keyword matches content_markdown but not content_html" do
    results = Article.search_keyword("爬虫")

    assert_includes results, @body_markdown_only
    assert_not_includes results, @body_html_only
  end

  test "search_keyword matches English in the body case-insensitively" do
    english_body = @account.articles.create!(
      title: "无关标题丁",
      url: "https://example.com/search-english-#{SecureRandom.hex(8)}",
      content_markdown: "This guide covers Ruby on Rails deployment.",
      published_at: 7.days.ago
    )

    assert_includes Article.search_keyword("RAILS deployment"), english_body
  end

  test "search_keyword ANDs space-separated terms" do
    assert_includes Article.search_keyword("爬虫 实战"), @in_title
    assert_includes Article.search_keyword("爬虫 框架"), @in_digest
    assert_includes Article.search_keyword("爬虫 工具"), @body_markdown_only

    cross_column = @account.articles.create!(
      title: "爬虫调度器",
      url: "https://example.com/search-cross-#{SecureRandom.hex(8)}",
      content_markdown: "核心是分布式队列",
      published_at: 8.days.ago
    )
    assert_includes Article.search_keyword("调度器 队列"), cross_column

    assert_empty Article.search_keyword("爬虫 不存在的词")
  end

  test "search_keyword treats SQL wildcards as literals" do
    percent = @account.articles.create!(
      title: "100% 全力冲刺",
      url: "https://example.com/search-wildcard-#{SecureRandom.hex(8)}",
      published_at: 6.days.ago
    )

    assert_includes Article.search_keyword("%"), percent
    assert_empty Article.search_keyword("%%")
    assert_empty Article.search_keyword("100_")
  end

  test "search_keyword is case-insensitive" do
    results = Article.search_keyword("TEST ARTICLE")

    assert_includes results, articles(:one)
    assert_not_includes results, @in_title
  end

  test "search_keyword returns all articles for blank keyword" do
    assert_equal Article.count, Article.search_keyword("").count
    assert_equal Article.count, Article.search_keyword(nil).count
    assert_equal Article.count, Article.search_keyword("   ").count
  end

  # search_keyword itself stays a pure SQL builder — the model's own tests above
  # call it with two-character terms. The cap lives in with_search_timeout, which
  # callers wrap around it.
  test "short_search_terms lists every term below the trigram minimum" do
    assert_equal [], Article.short_search_terms("爬虫调度")
    assert_equal [], Article.short_search_terms("爬虫调")
    assert_equal [], Article.short_search_terms(nil)
    assert_equal [], Article.short_search_terms("")

    assert_equal [ "甄劢" ], Article.short_search_terms("甄劢")
    assert_equal [ "a" ], Article.short_search_terms("a 爬虫调度")
    assert_equal [ "ab", "甄劢" ], Article.short_search_terms("ab 甄劢 爬虫调度")
  end

  test "short_search_timeout_message names the first short term or is nil" do
    assert_nil Article.short_search_timeout_message("爬虫调度")
    assert_nil Article.short_search_timeout_message(nil)

    message = Article.short_search_timeout_message("ab 甄劢")
    assert_includes message, "「ab」"
    assert_includes message, Article::MIN_SEARCH_TERM_LENGTH.to_s
    assert_includes message, (Article::SEARCH_TIMEOUT_MS / 1000.0).to_s
  end

  # The common case has to keep working: a two-character word that matches plenty
  # of articles (教育 matched 36,658 of them in 331ms on production) reaches its
  # LIMIT long before the cap, so the caller sees rows, not nil.
  test "with_search_timeout returns matches for a short term that finishes in time" do
    matched = @account.articles.create!(
      title: "教育行业观察",
      url: "https://example.com/search-short-#{SecureRandom.hex(8)}",
      published_at: 9.days.ago
    )

    results = Article.with_search_timeout("教育") do
      Article.search_keyword("教育").page(1).per(25).without_count
    end

    assert_includes results, matched
  end

  # The relation is loaded inside the transaction, so the block can return one
  # lazily — a relation left unloaded would run after COMMIT, where SET LOCAL no
  # longer applies. `requires_new` keeps the cancelled statement inside its own
  # savepoint, so an enclosing transaction (the test suite wraps each test in
  # one) survives and the connection stays usable.
  test "with_search_timeout returns nil when the scan is cut off" do
    stub_class_method(Article, :search_timeout_ms, -> { 20 }) do
      result = Article.with_search_timeout("甄劢") do
        Article.connection.execute("SELECT pg_sleep(0.5)")
      end

      assert_nil result

      # The shape callers actually use: a lazy relation, loaded by
      # with_search_timeout rather than by them.
      slow_relation = Article.from("(SELECT pg_sleep(0.5)) AS articles").page(1).per(25).without_count
      assert_nil Article.with_search_timeout("甄劢") { slow_relation }
    end

    assert_equal 1, Article.connection.select_value("SELECT 1")
  end

  # The cap is for short terms only. A keyword every term of which can use the
  # indexes must not be touched, or the 2.5s ceiling would apply to ordinary
  # searches too.
  test "with_search_timeout leaves index-served keywords uncapped" do
    stub_class_method(Article, :search_timeout_ms, -> { 20 }) do
      result = Article.with_search_timeout("爬虫调度") do
        Article.connection.execute("SELECT pg_sleep(0.5)")
      end

      assert_not_nil result
    end
  end

  # A blank keyword has no terms at all, so nothing to cap and nothing to search.
  test "with_search_timeout yields for a blank keyword" do
    assert_equal :ran, Article.with_search_timeout(nil) { :ran }
  end

  # The cap is only as good as its coverage: one call site outside
  # with_search_timeout silently reintroduces the ~28s scan. Fail here rather
  # than in production. Bodies are split per method so a file-level mention of
  # the cap (its own definition, in the model) cannot vouch for a method that
  # never applies it.
  test "every caller of search_keyword runs it under with_search_timeout" do
    root = Rails.root.to_s
    files = Dir.glob(File.join(root, "{app,lib}/**/*.rb")).select do |path|
      File.read(path).match?(/\.search_keyword\b/)
    end

    assert_not_empty files, "expected to find search_keyword call sites"

    uncapped = files.flat_map { |path|
      File.read(path).split(/^\s*def /).filter_map { |body|
        next unless body.match?(/\.search_keyword\b/)
        next if body.start_with?("self.search_keyword") # the definition, not a call
        next if body.include?("with_search_timeout")

        "#{path.sub("#{root}/", "")}##{body[/\A(?:self\.)?([a-z_?!]+)/, 1]}"
      }
    }

    assert_empty uncapped, "these call search_keyword without capping the scan"
  end
end
