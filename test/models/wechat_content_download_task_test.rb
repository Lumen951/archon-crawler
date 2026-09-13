require "test_helper"

# == Schema Information
#
# Table name: wechat_content_download_tasks
#
#  id                  :bigint           not null, primary key
#  articles_downloaded :integer          default(0), not null
#  articles_failed     :integer          default(0), not null
#  articles_total      :integer          default(0), not null
#  error_message       :text
#  finished_at         :datetime
#  heartbeat_at        :datetime         not null
#  started_at          :datetime
#  status              :integer          default(0), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  job_id              :string           not null
#
# Indexes
#
#  index_wechat_content_download_tasks_on_job_id  (job_id) UNIQUE
#
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
