# frozen_string_literal: true

require "test_helper"

class RednoteCrawlerTest < ActiveSupport::TestCase
  setup do
    @task = CrawlTask.new
    @account = RednoteAccount.new(nickname: "测试帐号", fakeid: "fakeid-1")
  end

  test "没有任何调用时返回 nil（由调用方保持原有日志输出）" do
    assert_nil RednoteCrawler.platform_crawl_summary(@task)
  end

  test "汇总调用次数、消耗与最后一次余额" do
    RednoteCrawler.track_usage(@task, @account, "笔记列表第 1 页",
                               RednoteApiClient::Usage.new(cost: 100, balance: 9_982_100))
    RednoteCrawler.track_usage(@task, @account, "笔记详情 note1",
                               RednoteApiClient::Usage.new(cost: 20, balance: 9_982_080))

    assert_equal "共调用 API 2 次，消耗 120 积分，余额 9982080",
                 RednoteCrawler.platform_crawl_summary(@task)
  end

  test "厂商未上报消耗时省略消耗分句" do
    RednoteCrawler.track_usage(@task, @account, "笔记详情 note1",
                               RednoteApiClient::Usage.new(cost: nil, balance: 500))

    assert_equal "共调用 API 1 次，余额 500", RednoteCrawler.platform_crawl_summary(@task)
  end

  test "完全没有金额时只报调用次数" do
    RednoteCrawler.track_usage(@task, @account, "笔记详情 note1",
                               RednoteApiClient::Usage.new(cost: nil, balance: nil))

    assert_equal "共调用 API 1 次", RednoteCrawler.platform_crawl_summary(@task)
  end

  test "只统计小红书帐号的调用，不受其他平台影响" do
    @task.api_usage_tally.record("WechatAccount", cost: 999, balance: 1)
    RednoteCrawler.track_usage(@task, @account, "笔记详情 note1",
                               RednoteApiClient::Usage.new(cost: 20, balance: 9_982_080))

    assert_equal "共调用 API 1 次，消耗 20 积分，余额 9982080",
                 RednoteCrawler.platform_crawl_summary(@task)
  end

  test "逐次调用写一条 debug 日志，数字在 message 里" do
    messages = []
    stub_class_method(RednoteCrawler, :log, ->(_task, level, message, context: nil) {
      messages << [ level, message, context ]
    }) do
      RednoteCrawler.track_usage(@task, @account, "笔记列表第 2 页",
                                 RednoteApiClient::Usage.new(cost: 100, balance: 9_982_100))
    end

    level, message, context = messages.first
    assert_equal :debug, level
    assert_equal "测试帐号: 笔记列表第 2 页 API 调用 — 消耗 100 积分，余额 9982100", message
    assert_equal({ kind: "api_usage", endpoint: "笔记列表第 2 页", cost: 100, balance: 9_982_100 }, context)
  end
end
