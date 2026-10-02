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

  # ── 采集通道分发 ──────────────────────────────────────

  test "provider=browser 时整个账号分发到 RednoteBrowserCrawler" do
    Option.rednote_crawl_provider = "browser"
    delegated = false
    stub_class_method(RednoteBrowserCrawler, :crawl_account, ->(*) { delegated = true; { new_count: 0, skip_count: 0, error_count: 0 } }) do
      RednoteCrawler.crawl_account(@account, @task, article_concurrency: 1, max_pages: 1)
    end

    assert delegated, "浏览器通道必须整账号委托 RednoteBrowserCrawler"
  ensure
    Option.delete_all
  end

  test "默认 provider=api 时不委托浏览器通道" do
    Option.delete_all
    assert_equal "api", Option.rednote_crawl_provider, "默认必须是付费 API 通道"

    account = RednoteAccount.create!(nickname: "API通道帐号", fakeid: "dispatch-api-1")
    task = CrawlTask.create!(account_ids: [ account.id ], status: :running)
    delegated = false
    api_called = false
    stub_class_method(RednoteBrowserCrawler, :crawl_account, ->(*) { delegated = true }) do
      stub_class_method(RednoteApiClient, :get_user_notes, ->(*, **) { api_called = true; { "notes" => [], "total_pages" => 1 } }) do
        RednoteCrawler.crawl_account(account, task, article_concurrency: 1, max_pages: 1)
      end
    end

    assert_not delegated
    assert api_called, "API 通道应照常调用付费接口"
  end

  # ── 共用落库入口 save_note_with_detail ────────────────

  test "save_note_with_detail 落库字段映射（标签/封面/毫秒时间/作者）" do
    account = RednoteAccount.create!(nickname: "存库帐号", fakeid: "save-mapping-1")
    task = CrawlTask.create!(account_ids: [ account.id ], status: :running)
    detail = {
      "note_card" => {
        "title" => "详情标题", "desc" => "正文内容",
        "image_list" => [ { "url_default" => "https://img/1.jpg" } ],
        "tag_list" => [ { "name" => "标签A" }, { "name" => nil } ],
        "time" => 1_714_500_000_000,
        "user" => { "nickname" => "作者乙" }
      }
    }

    result = RednoteCrawler.save_note_with_detail({ "noteId" => "abc1", "title" => "列表标题" }, detail, account, task)

    assert_equal :saved, result
    article = Article.find_by!(url: "https://www.xiaohongshu.com/explore/abc1")
    assert_equal "详情标题", article.title, "详情标题优先于列表标题"
    assert_equal "正文内容", article.content_markdown
    assert_equal "作者乙", article.author
    assert_equal "https://img/1.jpg", article.cover_url
    assert_includes article.digest, "#标签A"
    assert_equal Time.at(1_714_500_000).utc, article.published_at.utc, "毫秒时间戳正确换算"
  end

  test "save_note_with_detail 缺失发布时间保持 nil，绝不落到 Unix epoch" do
    account = RednoteAccount.create!(nickname: "存库帐号", fakeid: "save-epoch-1")
    task = CrawlTask.create!(account_ids: [ account.id ], status: :running)
    detail = { "note_card" => { "title" => "无时间笔记", "desc" => "正文" } }

    result = RednoteCrawler.save_note_with_detail({ "noteId" => "abc2" }, detail, account, task)

    assert_equal :saved, result
    article = Article.find_by!(url: "https://www.xiaohongshu.com/explore/abc2")
    assert_nil article.published_at
  ensure
    Article.find_by(url: "https://www.xiaohongshu.com/explore/abc2")&.destroy
  end

  test "save_note_with_detail 数据库唯一约束兜底重复笔记" do
    account = RednoteAccount.create!(nickname: "存库帐号", fakeid: "save-dup-1")
    task = CrawlTask.create!(account_ids: [ account.id ], status: :running)
    Article.create!(account: account, url: "https://www.xiaohongshu.com/explore/abc3", title: "已有笔记")

    result = RednoteCrawler.save_note_with_detail(
      { "noteId" => "abc3" },
      { "note_card" => { "title" => "重复笔记" } },
      account, task
    )

    assert_equal :skipped, result
    assert_equal 1, Article.where(url: "https://www.xiaohongshu.com/explore/abc3").count
  end

  test "fetch_and_save_note 命中已存 URL 直接跳过，不请求详情" do
    account = RednoteAccount.create!(nickname: "存库帐号", fakeid: "fetch-dup-1")
    task = CrawlTask.create!(account_ids: [ account.id ], status: :running)
    Article.create!(account: account, url: "https://www.xiaohongshu.com/explore/abc4", title: "已有笔记")

    stub_class_method(RednoteApiClient, :get_note_detail, ->(*) { flunk "重复笔记不应请求详情" }) do
      assert_equal :skipped, RednoteCrawler.fetch_and_save_note({ "noteId" => "abc4" }, account, task)
    end
  end

  test "fetch_and_save_note 详情获取失败按单篇错误返回" do
    account = RednoteAccount.create!(nickname: "存库帐号", fakeid: "fetch-nil-1")
    task = CrawlTask.create!(account_ids: [ account.id ], status: :running)

    stub_class_method(RednoteApiClient, :get_note_detail, ->(*, **) { nil }) do
      assert_equal :error, RednoteCrawler.fetch_and_save_note({ "noteId" => "abc5" }, account, task)
    end
    assert_nil Article.find_by(url: "https://www.xiaohongshu.com/explore/abc5")
  end
end
