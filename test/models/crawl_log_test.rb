# frozen_string_literal: true

require "test_helper"

class CrawlLogTest < ActiveSupport::TestCase
  setup do
    @task = CrawlTask.create!(status: :pending)
  end

  test "verbose_mode 关闭时不写入日志" do
    assert_not Option.verbose_mode?

    assert_no_difference "CrawlLog.count" do
      CrawlLog.log(@task, :info, "普通日志")
    end
  end

  test "force 为 true 时即使 verbose_mode 关闭也写入，并序列化 context" do
    assert_not Option.verbose_mode?

    assert_difference "CrawlLog.count", 1 do
      CrawlLog.log(@task, :info, "小红书 平台抓取完成，共调用 API 2 次",
                   context: { kind: "platform_api_usage", platform: "RednoteAccount", calls: 2, cost: 120 },
                   force: true)
    end

    log = CrawlLog.last
    assert_equal "info", log.level
    assert_equal "小红书 平台抓取完成，共调用 API 2 次", log.message
    assert_equal({ "kind" => "platform_api_usage", "platform" => "RednoteAccount", "calls" => 2, "cost" => 120 },
                 JSON.parse(log.context))
  end

  test "CrawlTask#log 透传 force" do
    assert_difference "CrawlLog.count", 1 do
      @task.log(:info, "任务级强制日志", force: true)
    end

    assert_no_difference "CrawlLog.count" do
      @task.log(:info, "任务级普通日志")
    end
  end
end
