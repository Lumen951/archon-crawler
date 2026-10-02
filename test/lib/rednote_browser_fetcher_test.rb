require "test_helper"

class RednoteBrowserFetcherTest < ActiveSupport::TestCase
  # 鸭子类型替身：BrowserSession 只用 go_to / evaluate / close。evaluate 按 JS
  # 特征分发到各测试注入的处理器。
  class FakePage
    attr_reader :navigated_to, :scroll_count, :closed

    def initialize(evaluate: ->(_js) { {} })
      @evaluate = evaluate
      @navigated_to = []
      @scroll_count = 0
      @closed = false
    end

    def go_to(url)
      @navigated_to << url
      self
    end

    def evaluate(js)
      if js.include?("window.scrollTo")
        @scroll_count += 1
        {}
      else
        @evaluate.call(js)
      end
    end

    def close
      @closed = true
    end

    def command(*) = {}
  end

  class FakeBrowser
    attr_reader :quit_called

    def initialize(page)
      @page = page
      @quit_called = false
    end

    def create_page = @page

    def quit = (@quit_called = true)
  end

  setup do
    Option.delete_all
    # 限流器窗口跨测试共享，放水避免滑动窗口拖慢套件；类级缓存要复位
    Option.rednote_browser_rate_limit = 1000
    RednoteBrowserFetcher.reset_rate_limiter!
  end

  # ── 归一化（纯函数） ──────────────────────────────────

  test "normalize_profile_payload 按 note_id 去重并保留首个 xsec_token" do
    payload = {
      "nickname" => "测试号",
      "hasMore" => false,
      "notes" => [
        { "id" => "note1", "xsec_token" => "tok-1", "title" => "第一篇", "cover" => "https://img/1.jpg" },
        { "id" => "note1", "xsec_token" => "tok-dup", "title" => "重复" },
        { "id" => "", "title" => "无 id 应丢弃" },
        { "id" => "note2", "xsec_token" => "", "title" => "第二篇", "cover" => "" }
      ]
    }

    result = RednoteBrowserFetcher.normalize_profile_payload(payload)

    assert_equal "测试号", result[:nickname]
    assert_equal false, result[:has_more]
    assert_equal [ "note1", "note2" ], result[:notes].map { |n| n[:note_id] }
    assert_equal "tok-1", result[:notes].first[:xsec_token], "重复 id 保留先出现的项"
    assert_equal "https://img/1.jpg", result[:notes].first[:cover_url]
  end

  test "normalize_profile_payload 只有显式 false 才认为没有更多" do
    assert_nil RednoteBrowserFetcher.normalize_profile_payload({ "notes" => [] })[:has_more]
    assert_equal false, RednoteBrowserFetcher.normalize_profile_payload({ "hasMore" => false, "notes" => [] })[:has_more]
    assert_empty RednoteBrowserFetcher.normalize_profile_payload("garbage")[:notes], "非 Hash 输入返回空结构而非抛错"
  end

  test "normalize_note_detail 状态数据优先、DOM 兜底" do
    payload = {
      "note" => {
        "title" => "浏览器标题",
        "desc" => "浏览器正文",
        "user" => { "nickname" => "作者甲" },
        "imageList" => [ { "url" => "https://img/state-1.jpg" } ],
        "tagList" => [ { "name" => "测试" } ]
      },
      "dom" => {
        "title" => "DOM 标题", "desc" => "DOM 正文", "author" => "DOM 作者",
        "images" => [ "https://img/dom-1.jpg" ], "tags" => [ "dom标签" ]
      }
    }

    detail = RednoteBrowserFetcher.normalize_note_detail(payload)

    assert_equal "浏览器标题", detail[:title]
    assert_equal "浏览器正文", detail[:desc]
    assert_equal "作者甲", detail[:author]
    assert_equal [ "https://img/state-1.jpg" ], detail[:images]
    assert_equal [ "测试" ], detail[:tags]
  end

  test "normalize_note_detail 缺失字段落到 DOM 兜底" do
    payload = {
      "note" => { "desc" => "只有正文" },
      "dom" => {
        "title" => "DOM 标题", "author" => "DOM 作者",
        "images" => [ "https://img/dom-1.jpg", "https://img/dom-1.jpg", "" ],
        "tags" => [ "标签A" ], "date_text" => "2024-05-01 12:00"
      }
    }

    detail = RednoteBrowserFetcher.normalize_note_detail(payload)

    assert_equal "DOM 标题", detail[:title]
    assert_equal "DOM 作者", detail[:author]
    assert_equal [ "https://img/dom-1.jpg" ], detail[:images], "DOM 图片去重去空"
    assert_equal [ "标签A" ], detail[:tags]
    # 北京时间 2024-05-01 12:00 = UTC 04:00
    assert_equal Time.find_zone("Asia/Shanghai").local(2024, 5, 1, 12, 0).to_i * 1000, detail[:time_ms]
  end

  test "normalize_note_detail 的 time 兼容秒/毫秒并拒绝非法值" do
    assert_equal 1_714_500_000_000, RednoteBrowserFetcher.normalize_note_detail({ "note" => { "desc" => "x", "time" => 1_714_500_000_000 } })[:time_ms]
    assert_equal 1_714_500_000_000, RednoteBrowserFetcher.normalize_note_detail({ "note" => { "desc" => "x", "time" => 1_714_500_000 } })[:time_ms], "秒级时间戳换算成毫秒"
    assert_nil RednoteBrowserFetcher.normalize_note_detail({ "note" => { "desc" => "x", "time" => "abc" } })[:time_ms]
    assert_nil RednoteBrowserFetcher.normalize_note_detail({ "note" => { "desc" => "x", "time" => 0 } })[:time_ms]
    assert_nil RednoteBrowserFetcher.normalize_note_detail({ "note" => { "desc" => "x" }, "dom" => { "date_text" => "3天前" } })[:time_ms], "相对时间不猜测"
  end

  test "normalize_note_detail 没有任何可用数据时返回 nil" do
    assert_nil RednoteBrowserFetcher.normalize_note_detail(nil)
    assert_nil RednoteBrowserFetcher.normalize_note_detail({ "note" => {}, "dom" => {} })
  end

  test "detail_to_api_shape 映射成 save_note_with_detail 的输入契约并透传原始 payload" do
    detail = {
      title: "标题", desc: "正文", images: [ "https://img/1.jpg" ],
      tags: [ "标签" ], author: "作者", time_ms: 1_714_500_000_000
    }
    raw = { "note" => { "title" => "标题" } }

    shape = RednoteBrowserFetcher.detail_to_api_shape(detail, raw_payload: raw)

    assert_equal "标题", shape["note_card"]["title"]
    assert_equal "正文", shape["note_card"]["desc"]
    assert_equal [ { "url" => "https://img/1.jpg" } ], shape["note_card"]["image_list"]
    assert_equal [ { "name" => "标签" } ], shape["note_card"]["tag_list"]
    assert_equal 1_714_500_000_000, shape["note_card"]["time"]
    assert_equal "作者", shape["note_card"]["user"]["nickname"]
    assert_equal raw, shape["browser_raw"], "原始提取结果必须保留，用于区分解析器产物与上游原值"
  end

  test "note_detail_url 附加 xsec_source 与转义后的 xsec_token" do
    assert_equal "https://www.xiaohongshu.com/explore/abc123?xsec_source=pc_user",
                 RednoteBrowserFetcher.note_detail_url("abc123")
    assert_equal "https://www.xiaohongshu.com/explore/abc123?xsec_source=pc_user&xsec_token=tok%2Ba",
                 RednoteBrowserFetcher.note_detail_url("abc123", "tok+a")
  end

  # ── 会话流程（FakePage 驱动） ─────────────────────────

  test "fetch_profile_notes 首轮就有数据且 hasMore=false 时不滚动" do
    page = FakePage.new(evaluate: profile_payload(nickname: "测试号", notes: [ listing_note("note1") ]))
    session = new_session(page)

    result = session.fetch_profile_notes("user-1", max_scrolls: 5)

    assert_equal "测试号", result[:nickname]
    assert_equal [ "note1" ], result[:notes].map { |n| n[:note_id] }
    assert_equal false, result[:truncated]
    assert_equal "https://www.xiaohongshu.com/user/profile/user-1", page.navigated_to.first
    assert_equal 0, page.scroll_count
  end

  test "fetch_profile_notes 滚动收集增量并在连续空轮后停止" do
    rounds = [ { "nickname" => "测试号", "notes" => [ listing_note("note1") ] },
               { "notes" => [ listing_note("note2") ] },
               { "notes" => [] }, { "notes" => [] }, { "notes" => [] } ]
    index = -1
    page = FakePage.new(evaluate: ->(js) do
      next {} unless js.include?("__INITIAL_STATE__.user")
      index += 1
      rounds[[ index, rounds.size - 1 ].min]
    end)
    session = new_session(page)

    result = session.fetch_profile_notes("user-1", max_scrolls: 10)

    assert_equal [ "note1", "note2" ], result[:notes].map { |n| n[:note_id] }
    assert_equal 4, page.scroll_count, "两轮空结果即停止（IDLE_ROUNDS_BEFORE_STOP）"
    assert result[:truncated], "没有 hasMore=false 信号时必须如实标记可能不完整"
  end

  test "fetch_profile_notes 达到滚动轮数上限时停止" do
    # 持续返回笔记且无 hasMore 信号：只能靠轮数上限停下
    payload_without_more = ->(js) do
      js.include?("__INITIAL_STATE__.user") ? { "nickname" => "测试号", "notes" => [ listing_note("note1") ] } : {}
    end
    page = FakePage.new(evaluate: payload_without_more)
    session = new_session(page)

    result = session.fetch_profile_notes("user-1", max_scrolls: 2)

    assert_equal 2, page.scroll_count
    assert result[:truncated], "没有 hasMore=false 信号时必须如实标记可能不完整"
  end

  test "主页风控文案抛 RiskControlError 而不是被当成空账号" do
    page = FakePage.new(evaluate: risk_payload)
    session = new_session(page)

    error = assert_raises(RednoteBrowserFetcher::RiskControlError) do
      session.fetch_profile_notes("user-1")
    end
    assert_match(/300012|代理/, error.message)
  end

  test "昵称与笔记皆为空抛 LoginRequiredError" do
    page = FakePage.new(evaluate: profile_payload(nickname: "", notes: []))
    session = new_session(page)

    error = assert_raises(RednoteBrowserFetcher::LoginRequiredError) do
      session.fetch_profile_notes("user-1")
    end
    assert_match(/重新完成小红书网页版登录/, error.message)
  end

  test "fetch_note_detail 返回原始 payload 供归一与留痕" do
    note_payload = {
      "note" => { "title" => "标题", "desc" => "正文", "time" => 1_714_500_000_000 },
      "dom" => {}, "blocked" => false
    }
    page = FakePage.new(evaluate: ->(js) do
      js.include?("noteDetailMap") ? note_payload : {}
    end)
    session = new_session(page)

    payload = session.fetch_note_detail("note1", xsec_token: "tok")

    assert_equal note_payload, payload
    assert_includes page.navigated_to.first, "xsec_token=tok", "详情页跳转必须携带列表页的 xsec_token"
    assert_includes page.navigated_to.first, "xsec_source=pc_user"
  end

  test "fetch_note_detail 明确不可见的笔记抛 NoteUnavailableError" do
    page = FakePage.new(evaluate: ->(js) do
      js.include?("noteDetailMap") ? { "note" => nil, "dom" => {}, "blocked" => true } : {}
    end)
    session = new_session(page)

    assert_raises(RednoteBrowserFetcher::NoteUnavailableError) do
      session.fetch_note_detail("note1")
    end
  end

  test "open_session 附着登录浏览器并在结束后关闭标签页" do
    page = FakePage.new(evaluate: profile_payload(nickname: "测试号", notes: [ listing_note("note1") ]))
    browser = FakeBrowser.new(page)
    record = { "port" => 4001, "pid" => 4242 }

    stub_class_method(BrowserLogin::Session, :active_record, ->(_key) { record }) do
      stub_class_method(BrowserLogin::Session, :orphan_record, ->(_key) { nil }) do
        stub_class_method(BrowserLogin::Launcher, :attach, ->(_port) { browser }) do
          RednoteBrowserFetcher.open_session do |session|
            result = session.fetch_profile_notes("user-1", max_scrolls: 0)
            assert_equal "测试号", result[:nickname]
          end
        end
      end
    end

    assert page.closed, "附着会话抓取完后应关闭新开的标签页"
    assert browser.quit_called, "附着模式 quit 只断开 CDP，不杀登录浏览器进程"
  end

  private

  # settle sleep 在替身会话上短路（单例方法先于 Kernel 查找）
  def new_session(page)
    session = RednoteBrowserFetcher::BrowserSession.new(page, nil)
    session.define_singleton_method(:sleep) { |_seconds| nil }
    session
  end

  def listing_note(id, xsec: "tok-#{id}")
    { "id" => id, "xsec_token" => xsec, "title" => "标题-#{id}", "cover" => "https://img/#{id}.jpg" }
  end

  def profile_payload(nickname:, notes:)
    ->(js) { js.include?("__INITIAL_STATE__.user") ? { "nickname" => nickname, "hasMore" => false, "notes" => notes } : {} }
  end

  def risk_payload
    ->(js) { js.include?("document.body.innerText") ? "IP 存在风险，错误码 300012，请切换到安全网络" : {} }
  end
end
