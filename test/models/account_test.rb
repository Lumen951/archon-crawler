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
