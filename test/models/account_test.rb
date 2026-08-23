require "test_helper"

class AccountTest < ActiveSupport::TestCase
  # `activity_level` (instance method) and `by_activity_level` (scope) must
  # classify accounts into the exact same buckets. This test locks that
  # invariant so the two can never drift apart again.
  def test_activity_level_matches_by_activity_level_scope
    prefix = "activity_level_test_"
    now = Time.current

    # uncrawled — never crawled
    uncrawled = create_account(prefix, "uncrawled", last_crawled_at: nil, total_articles: 0, last_published_at: nil)

    # never — crawled but no articles
    never = create_account(prefix, "never", last_crawled_at: now - 2.days, total_articles: 0, last_published_at: nil)

    # active — published within 7 days
    active = create_account(prefix, "active", last_crawled_at: now - 1.day, total_articles: 3, last_published_at: now - 1.day)

    # slow — published 8–30 days ago
    slow = create_account(prefix, "slow", last_crawled_at: now - 10.days, total_articles: 5, last_published_at: now - 10.days)

    # dormant — published 31–90 days ago
    dormant = create_account(prefix, "dormant", last_crawled_at: now - 60.days, total_articles: 8, last_published_at: now - 60.days)

    # dead — published > 90 days ago
    dead_old = create_account(prefix, "dead_old", last_crawled_at: now - 120.days, total_articles: 2, last_published_at: now - 120.days)

    # dead — has articles but no publish timestamp
    dead_nil = create_account(prefix, "dead_nil", last_crawled_at: now - 5.days, total_articles: 2, last_published_at: nil)

    expected = {
      "uncrawled" => [ uncrawled ],
      "never"     => [ never ],
      "active"    => [ active ],
      "slow"      => [ slow ],
      "dormant"   => [ dormant ],
      "dead"      => [ dead_old, dead_nil ],
    }

    expected.each do |level, accounts|
      accounts.each do |account|
        assert_equal level.to_sym, account.activity_level, "#{account.fakeid} should be #{level}"
      end
    end

    scoped = Account.where("fakeid LIKE ?", "#{prefix}%")
    expected.each do |level, accounts|
      assert_equal accounts.map(&:id).sort,
                   scoped.by_activity_level(level).pluck(:id).sort,
                   "by_activity_level(#{level}) should match activity_level classification"
    end

    # The six buckets must partition the scoped set exactly (no overlap/gaps).
    assert_equal scoped.count, expected.values.flatten.size
  end

  def test_new_accounts_by_platform_counts_recent_creations
    travel_to Time.zone.local(2026, 8, 23, 12, 0, 0) do
      base = Account.new_accounts_by_platform(7.days.ago)

      account = Account.create!(type: "WechatAccount", nickname: "growth test", fakeid: "growth_test_1", status: :active)
      account.update_column(:created_at, 3.days.ago)

      after = Account.new_accounts_by_platform(7.days.ago)
      assert_equal base["微信公众号"] + 1, after["微信公众号"],
                   "an account created 3 days ago should be counted in the last-7-days window"
    end
  end

  def test_activity_crawl_progress_computes_due_backlog
    prefix = "progress_test_"
    # uncrawled: never crawled → always due
    create_account(prefix, "uncrawled", last_crawled_at: nil, total_articles: 0, last_published_at: nil)
    # never: crawled but no articles, next crawl scheduled in the future → not due
    never = create_account(prefix, "never", last_crawled_at: 2.days.ago, total_articles: 0, last_published_at: nil)
    never.update_column(:next_crawl_at, 10.days.from_now)
    # active: crawled, next crawl scheduled in the future → not due
    active = create_account(prefix, "active", last_crawled_at: 1.day.ago, total_articles: 3, last_published_at: 1.day.ago)
    active.update_column(:next_crawl_at, 1.hour.from_now)

    progress = Account.activity_crawl_progress(Account.where("fakeid LIKE ?", "#{prefix}%"))
                 .index_by { |row| row[:key] }

    assert_equal 1, progress[:uncrawled][:total]
    assert_equal 0, progress[:uncrawled][:crawled]
    assert_equal 1, progress[:uncrawled][:due], "uncrawled active accounts are always due"
    assert_equal 0, progress[:uncrawled][:pct], "all due → 0% caught up"

    assert_equal 1, progress[:never][:total]
    assert_equal 1, progress[:never][:crawled]
    assert_equal 0, progress[:never][:due]
    assert_equal 100, progress[:never][:pct], "none due → 100% caught up"

    assert_equal 1, progress[:active][:total]
    assert_equal 1, progress[:active][:crawled]
    assert_equal 0, progress[:active][:due]
    assert_equal 100, progress[:active][:pct]
  end

  private

  def create_account(prefix, slug, last_crawled_at:, total_articles:, last_published_at:)
    Account.create!(
      type: "WechatAccount",
      nickname: "activity test #{slug}",
      fakeid: "#{prefix}#{slug}",
      status: :active,
      last_crawled_at: last_crawled_at,
      total_articles: total_articles,
      last_published_at: last_published_at,
    )
  end
end
