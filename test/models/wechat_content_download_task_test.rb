require "test_helper"

class WechatContentDownloadTaskTest < ActiveSupport::TestCase
  setup do
    WechatContentDownloadTask.delete_all
  end

  test "alive includes active runs with a fresh heartbeat" do
    task = WechatContentDownloadTask.create!(job_id: "fresh-1", status: :running, heartbeat_at: Time.current)

    assert_includes WechatContentDownloadTask.alive, task
  end

  test "alive excludes active runs whose heartbeat is stale" do
    WechatContentDownloadTask.create!(job_id: "stale-1", status: :running, heartbeat_at: 2.hours.ago)

    assert_empty WechatContentDownloadTask.alive
  end
end
