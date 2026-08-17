require "test_helper"

class WechatContentDownloadJobTest < ActiveSupport::TestCase
  setup do
    WechatContentDownloadTask.delete_all
  end

  test "skips when an active run has a fresh heartbeat" do
    active = WechatContentDownloadTask.create!(job_id: "active-1", status: :running, heartbeat_at: Time.current)

    WechatContentDownloadJob.perform_now

    assert_equal 1, WechatContentDownloadTask.count
    assert_equal "running", active.reload.status
  end

  test "takes over a stale run and completes when no content is missing" do
    stale = WechatContentDownloadTask.create!(job_id: "stale-1", status: :running, heartbeat_at: 2.hours.ago)

    WechatContentDownloadJob.perform_now

    assert_equal "stale", stale.reload.status
    successor = WechatContentDownloadTask.where.not(id: stale.id).sole
    assert_equal "completed", successor.status
  end

  test "record_download! increments the right counter and refreshes the heartbeat" do
    task = WechatContentDownloadTask.create!(job_id: "t-1", status: :running, heartbeat_at: 1.hour.ago)

    task.record_download!(true)
    task.reload
    assert_equal 1, task.articles_downloaded
    assert_equal 0, task.articles_failed
    assert_operator task.heartbeat_at, :>, 1.minute.ago

    task.record_download!(false)
    task.reload
    assert_equal 1, task.articles_downloaded
    assert_equal 1, task.articles_failed
  end

  test "wechat_missing_content orders newest first" do
    account = WechatAccount.create!(nickname: "Scope Account", fakeid: "scope_fakeid_1", status: :active)

    Article.create!(account: account, title: "oldest", url: "https://example.com/oldest", published_at: 3.days.ago)
    Article.create!(account: account, title: "newest", url: "https://example.com/newest", published_at: 1.day.ago)
    Article.create!(account: account, title: "middle", url: "https://example.com/middle", published_at: 2.days.ago)

    titles = Article.wechat_missing_content.order(published_at: :desc).pluck(:title)

    assert_equal %w[newest middle oldest], titles
  end
end
