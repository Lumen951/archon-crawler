require "test_helper"

class RednoteBrowserCrawlerTest < ActiveSupport::TestCase
  # 鸭子类型替身：RednoteBrowserCrawler 只用 fetch_profile_notes /
  # fetch_note_detail（xsec_token:、xsec_source:）。
  class FakeSession
    attr_reader :requested_details

    def initialize(listing:, payloads: {}, errors: {})
      @listing = listing
      @payloads = payloads
      @errors = errors
      @requested_details = []
    end

    def fetch_profile_notes(_user_id, max_scrolls: nil)
      @max_scrolls = max_scrolls
      @listing
    end

    def max_scrolls_used = @max_scrolls

    def fetch_note_detail(note_id, xsec_token: nil, xsec_source: nil)
      @requested_details << [ note_id, xsec_token, xsec_source ]
      raise @errors[note_id] if @errors[note_id]

      @payloads[note_id]
    end
  end

  setup do
    Option.delete_all
    @account = RednoteAccount.create!(nickname: "浏览器帐号", fakeid: "browser-fakeid-1")
    @task = CrawlTask.create!(account_ids: [ @account.id ], status: :running)
    CrawlTaskAccount.create!(crawl_task: @task, account: @account)
  end

  teardown do
    Article.where(account: @account).delete_all
    CrawlTaskAccount.where(crawl_task: @task).delete_all
    @task.destroy
    @account.destroy
  end

  def stub_session(session)
    stub_class_method(RednoteBrowserFetcher, :open_session,
                      ->(crawl_task: nil, &block) { block.call(session) }) do
      yield
    end
  end

  def browser_payload(note_id, time: 1_714_500_000_000)
    {
      "note" => {
        "title" => "浏览器标题-#{note_id}",
        "desc" => "浏览器正文-#{note_id}",
        "time" => time,
        "user" => { "nickname" => "作者甲" },
        "imageList" => [ { "url" => "https://img/#{note_id}.jpg" } ],
        "tagList" => [ { "name" => "测试标签" } ]
      },
      "dom" => {},
      "blocked" => false
    }
  end

  test "滚动上限：max_pages>0 按近似系数换算，未限制时用全局配置" do
    assert_equal 4, RednoteBrowserCrawler.scroll_cap(2)
    Option.rednote_browser_max_scrolls = 17
    assert_equal 17, RednoteBrowserCrawler.scroll_cap(-1)
  end

  test "浏览器通道保存笔记：字段映射、跳转凭证透传、raw_data 保留来源" do
    session = FakeSession.new(
      listing: { nickname: "测试号", truncated: false,
                 notes: [ { note_id: "note1", xsec_token: "tok-1", xsec_source: "profile_feed", title: "列表标题", cover_url: "" } ] },
      payloads: { "note1" => browser_payload("note1") }
    )

    result = stub_session(session) do
      RednoteBrowserCrawler.crawl_account(@account, @task, article_concurrency: 3, max_pages: 1)
    end

    assert_equal({ new_count: 1, skip_count: 0, error_count: 0 }, result)
    assert_equal [ [ "note1", "tok-1", "profile_feed" ] ], session.requested_details, "详情页必须携带列表页的跳转凭证"
    assert_equal 2, session.max_scrolls_used, "max_pages=1 换算成 2 轮滚动"

    article = Article.find_by(url: "https://www.xiaohongshu.com/explore/note1")
    assert_not_nil article
    assert_equal "浏览器标题-note1", article.title
    assert_equal "浏览器正文-note1", article.content_markdown
    assert_equal "作者甲", article.author
    assert_equal "https://img/note1.jpg", article.cover_url
    assert_includes article.digest, "浏览器正文-note1"
    assert_includes article.digest, "#测试标签"
    assert_equal Time.at(1_714_500_000).utc, article.published_at.utc
    assert_equal "浏览器标题-note1", article.raw_data.dig("browser_raw", "note", "title"),
                 "raw_data 必须带 browser_raw 来源痕迹，区分解析器产物与上游原值"

    task_account = @task.crawl_task_accounts.first
    assert_equal "completed", task_account.status
  end

  test "缺失发布时间保持 nil，绝不落到 Unix epoch" do
    session = FakeSession.new(
      listing: { nickname: "测试号", truncated: false,
                 notes: [ { note_id: "note1", xsec_token: "tok", title: "", cover_url: "" } ] },
      payloads: { "note1" => {
        "note" => { "desc" => "正文", "user" => { "nickname" => "作者" } },
        "dom" => { "date_text" => "3天前" }, "blocked" => false
      } }
    )

    stub_session(session) do
      RednoteBrowserCrawler.crawl_account(@account, @task, article_concurrency: 1, max_pages: 1)
    end

    article = Article.find_by(url: "https://www.xiaohongshu.com/explore/note1")
    assert_not_nil article
    assert_nil article.published_at
    assert_equal "(无标题)", article.title, "列表标题为空时回退占位符"
  end

  test "已存在的笔记 URL 直接跳过，不发起详情请求" do
    Article.create!(account: @account, url: "https://www.xiaohongshu.com/explore/note1", title: "旧笔记")
    session = FakeSession.new(
      listing: { nickname: "测试号", truncated: false,
                 notes: [ { note_id: "note1", xsec_token: "tok", title: "重复", cover_url: "" } ] }
    )

    result = stub_session(session) do
      RednoteBrowserCrawler.crawl_account(@account, @task, article_concurrency: 1, max_pages: 1)
    end

    assert_equal({ new_count: 0, skip_count: 1, error_count: 0 }, result)
    assert_empty session.requested_details, "重复笔记不应打开详情页"
    assert_equal 1, Article.where(url: "https://www.xiaohongshu.com/explore/note1").count
  end

  test "详情读取失败按单篇错误计数，不中断其余笔记" do
    session = FakeSession.new(
      listing: { nickname: "测试号", truncated: false,
                 notes: [
                   { note_id: "note-bad", xsec_token: "tok", title: "坏笔记", cover_url: "" },
                   { note_id: "note-good", xsec_token: "tok", title: "好笔记", cover_url: "" }
                 ] },
      payloads: { "note-good" => browser_payload("note-good") }
    )

    result = stub_session(session) do
      RednoteBrowserCrawler.crawl_account(@account, @task, article_concurrency: 1, max_pages: 1)
    end

    assert_equal({ new_count: 1, skip_count: 0, error_count: 1 }, result)
    assert_nil Article.find_by(url: "https://www.xiaohongshu.com/explore/note-bad")
    assert_not_nil Article.find_by(url: "https://www.xiaohongshu.com/explore/note-good")
  end

  test "笔记不可见（NoteUnavailableError）按单篇错误处理，继续后面的笔记" do
    session = FakeSession.new(
      listing: { nickname: "测试号", truncated: false,
                 notes: [
                   { note_id: "note-gone", xsec_token: "tok", title: "被删笔记", cover_url: "" },
                   { note_id: "note-good", xsec_token: "tok", title: "好笔记", cover_url: "" }
                 ] },
      payloads: { "note-good" => browser_payload("note-good") },
      errors: { "note-gone" => RednoteBrowserFetcher::NoteUnavailableError.new("笔记 note-gone 无法浏览") }
    )

    result = stub_session(session) do
      RednoteBrowserCrawler.crawl_account(@account, @task, article_concurrency: 1, max_pages: 1)
    end

    assert_equal({ new_count: 1, skip_count: 0, error_count: 1 }, result)
  end

  test "风控拦截终止本账号并标记 task_account 失败，留下可操作指引" do
    session = FakeSession.new(listing: {}, errors: {})
    def session.fetch_profile_notes(_user_id, max_scrolls: nil)
      raise RednoteBrowserFetcher::RiskControlError, "检测到小红书风控拦截（IP 存在风险，错误码 300012）"
    end

    result = stub_session(session) do
      RednoteBrowserCrawler.crawl_account(@account, @task, article_concurrency: 1, max_pages: 1)
    end

    assert_equal({ new_count: 0, skip_count: 0, error_count: 1 }, result)
    assert_equal "failed", @task.crawl_task_accounts.first.status
    # 风控不 fail_platform：其他账号可能仍可尝试，由 error threshold 兜底
    assert_not_equal 50, @task.platform_error_count("RednoteAccount")
  end

  test "登录态失效同样终止本账号并如实落失败状态" do
    session = FakeSession.new(listing: {}, errors: {})
    def session.fetch_profile_notes(_user_id, max_scrolls: nil)
      raise RednoteBrowserFetcher::LoginRequiredError, "无法读取小红书主页数据"
    end

    result = stub_session(session) do
      RednoteBrowserCrawler.crawl_account(@account, @task, article_concurrency: 1, max_pages: 1)
    end

    assert_equal({ new_count: 0, skip_count: 0, error_count: 1 }, result)
    assert_equal "failed", @task.crawl_task_accounts.first.status
  end

  test "浏览器意外错误（如启动失败）留下准确的账号失败状态" do
    stub_class_method(RednoteBrowserFetcher, :open_session,
                      ->(crawl_task: nil) { raise RednoteBrowserFetcher::Error, "拉起小红书抓取浏览器失败：Ferrum::Error" }) do
      result = RednoteBrowserCrawler.crawl_account(@account, @task, article_concurrency: 1, max_pages: 1)

      assert_equal({ new_count: 0, skip_count: 0, error_count: 1 }, result)
      assert_equal "failed", @task.crawl_task_accounts.first.status
      assert_equal 1, @task.platform_error_count("RednoteAccount")
    end
  end
end
