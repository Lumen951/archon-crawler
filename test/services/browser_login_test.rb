require "test_helper"

class BrowserLoginTest < ActiveSupport::TestCase
  setup { Option.delete_all }

  # Ferrum cookie 对象的鸭子类型替身（只用 name/value/domain）
  Cookie = Struct.new(:name, :value, :domain)

  # BrowserLogin::WechatMp#save! 需要的页面接口：url / evaluate / go_to
  class FakePage
    attr_reader :navigations

    def initialize(url:, html: "")
      @url = url
      @html = html
      @navigations = []
    end

    def url
      @url
    end

    def evaluate(_expression)
      @html
    end

    def go_to(target)
      @navigations << target
      @url = "https://mp.weixin.qq.com/cgi-bin/home?t=home/index&lang=zh_CN&token=98765"
      @html = ""
      target
    end
  end

  test "find returns the provider class and raises on unknown keys" do
    assert_equal BrowserLogin::WechatMp, BrowserLogin.find("wechat_mp")
    assert_equal BrowserLogin::RednoteWeb, BrowserLogin.find(:rednote_web)
    assert_equal BrowserLogin::WereadNative, BrowserLogin.find("weread_native")
    assert_raises(BrowserLogin::Error) { BrowserLogin.find("nope") }
  end

  # ── WechatMp ─────────────────────────────────────────

  test "wechat_mp logged_in? requires slave_user and slave_sid on qq.com" do
    partial = [ Cookie.new("slave_user", "u", ".qq.com") ]
    complete = partial + [ Cookie.new("slave_sid", "s", "mp.weixin.qq.com") ]
    foreign = [ Cookie.new("slave_user", "u", ".example.com") ]

    assert_not BrowserLogin::WechatMp.logged_in?(partial)
    assert_not BrowserLogin::WechatMp.logged_in?(foreign)
    assert BrowserLogin::WechatMp.logged_in?(complete)
  end

  test "wechat_mp save! exports the qq.com cookie string and token into Option" do
    page = FakePage.new(url: "https://mp.weixin.qq.com/cgi-bin/home?t=home/index&lang=zh_CN&token=12345")
    cookies = [
      Cookie.new("slave_user", "u", ".qq.com"),
      Cookie.new("slave_sid", "s", ".qq.com"),
      Cookie.new("other", "x", ".example.com")
    ]

    identity = BrowserLogin::WechatMp.save!(page: page, cookies: cookies)

    assert_equal "slave_user=u; slave_sid=s", Option.wechat_mp_cookie
    assert_equal "12345", Option.wechat_mp_token
    assert Option.wechat_mp_session_valid?
    assert_equal [], page.navigations, "URL 已带 token 时不应额外导航"
    assert_equal "微信公众号平台", identity, "取不到昵称时应回退到平台名"
  end

  test "wechat_mp save! navigates home to pick up the token when missing" do
    page = FakePage.new(url: "https://mp.weixin.qq.com/")
    cookies = [ Cookie.new("slave_user", "u", ".qq.com"), Cookie.new("slave_sid", "s", ".qq.com") ]

    BrowserLogin::WechatMp.save!(page: page, cookies: cookies)

    assert_equal [ BrowserLogin::WechatMp.login_url ], page.navigations
    assert_equal "98765", Option.wechat_mp_token
  end

  # ── RednoteWeb ───────────────────────────────────────

  # 小红书对匿名访客也下发 web_session（实测访客 jar 含 web_session，值以 0300 开头），
  # 因此这里刻意不自动判定，避免把访客会话当登录态存下来
  test "rednote_web never auto-detects login from cookies" do
    guest_like = [
      Cookie.new("a1", "1a0e999", ".xiaohongshu.com"),
      Cookie.new("webId", "59e6401", ".xiaohongshu.com"),
      Cookie.new("web_session", "030037ad8992", ".xiaohongshu.com")
    ]
    assert_not BrowserLogin::RednoteWeb.logged_in?(guest_like)
    assert_not BrowserLogin::RednoteWeb.logged_in?([])
  end

  test "rednote_web save! stores the cookie string in its own slot" do
    page = FakePage.new(url: "https://www.xiaohongshu.com/", html: "")
    cookies = [ Cookie.new("web_session", "abc", ".xiaohongshu.com"), Cookie.new("a1", "z", ".xiaohongshu.com") ]

    BrowserLogin::RednoteWeb.save!(page: page, cookies: cookies)

    assert_equal "web_session=abc; a1=z", Option.rednote_web_cookie
    assert Option.rednote_web_session_valid?
    assert_not_equal Option.rednote_web_cookie, Option.wechat_mp_cookie, "不得写入微信会话槽位"
  end

  # ── WereadNative ─────────────────────────────────────

  test "weread_native logged_in? requires wr_vid and wr_skey" do
    assert_not BrowserLogin::WereadNative.logged_in?([ Cookie.new("wr_vid", "1", ".qq.com") ])
    assert BrowserLogin::WereadNative.logged_in?(
      [ Cookie.new("wr_vid", "1", ".qq.com"), Cookie.new("wr_skey", "k", ".qq.com") ]
    )
  end

  test "weread_native save! writes the qq.com cookie jar into Option" do
    page = FakePage.new(url: "https://weread.qq.com/")
    cookies = [
      Cookie.new("wr_vid", "123", ".qq.com"),
      Cookie.new("wr_skey", "key", ".qq.com"),
      Cookie.new("wr_gid", "g", ".qq.com"),
      Cookie.new("unrelated", "x", ".example.com")
    ]

    identity = BrowserLogin::WereadNative.save!(page: page, cookies: cookies)

    jar = Option.weread_native_cookie_jar
    assert_equal({ "wr_vid" => "123", "wr_skey" => "key", "wr_gid" => "g" }, jar)
    assert Option.weread_native_session_valid?
    assert_match(/123/, identity)
  end

  # ── Session.frame 的截图契约 ──────────────────────────
  # Ferrum 的 page.screenshot（不给 path）返回的就是 base64 字符串。
  # 再编码一次会让前端拿到坏图，这里锁住"原样透传"。
  test "frame passes the base64 screenshot through without re-encoding" do
    jpeg = "\xFF\xD8\xFF\xE0fake-jpeg".b
    encoded = Base64.strict_encode64(jpeg)

    fake_page = Object.new
    fake_page.define_singleton_method(:cookies) { Struct.new(:all).new({}) }
    fake_page.define_singleton_method(:screenshot) { |**| encoded }
    fake_page.define_singleton_method(:url) { "https://mp.weixin.qq.com/" }

    record = {
      "session_id" => "s-frame", "provider" => "wechat_mp", "port" => 1, "pid" => 1,
      "created_at" => Time.current.iso8601, "last_activity_at" => Time.current.iso8601
    }

    with_memory_cache do
      Rails.cache.write("browser_login:session:s-frame", record)

      stub_class_method(BrowserLogin::Session, :with_page, ->(_record, &block) { block.call(fake_page) }) do
        result = BrowserLogin::Session.frame("s-frame")

        assert_equal encoded, result[:image], "必须是 Ferrum 返回的 base64 原样透传"
        assert_equal [ 255, 216, 255 ], Base64.decode64(result[:image])[0, 3].bytes
        assert_equal "image/jpeg", result[:image_mime]
        assert_equal false, result[:logged_in], "没有登录 Cookie 时不应误判为已登录"
      end
    end
  end

  test "frame without a live session raises NotFoundError" do
    with_memory_cache do
      assert_raises(BrowserLogin::Session::NotFoundError) { BrowserLogin::Session.frame("nope") }
    end
  end

  # ── 地址栏导航 ────────────────────────────────────────

  test "interact navigate drives the remote page and rejects non-http schemes" do
    commands = []
    fake_page = Object.new
    fake_page.define_singleton_method(:command) { |name, **params| commands << [ name, params ]; {} }
    record = {
      "session_id" => "s-nav", "provider" => "wechat_mp", "port" => 1, "pid" => 1,
      "created_at" => Time.current.iso8601, "last_activity_at" => Time.current.iso8601
    }

    with_memory_cache do
      Rails.cache.write("browser_login:session:s-nav", record)

      stub_class_method(BrowserLogin::Session, :with_page, ->(_record, &block) { block.call(fake_page) }) do
        BrowserLogin::Session.interact("s-nav", type: "navigate", url: "https://mp.weixin.qq.com/s/abc")

        error = assert_raises(BrowserLogin::Error) do
          BrowserLogin::Session.interact("s-nav", type: "navigate", url: "javascript:alert(1)")
        end
        assert_match(/http\/https/, error.message)
      end
    end

    assert_equal [ "Page.navigate", { url: "https://mp.weixin.qq.com/s/abc" } ], commands.last
  end

  # 滑块拼图验证：前端把 pointerdown/move/up 逐个转发，服务端按序驱动鼠标。
  # move→down 组合保证 mousePressed 落在正确坐标上。
  test "interact dispatches granular mouse events for remote dragging" do
    calls = []
    fake_mouse = Object.new
    fake_mouse.define_singleton_method(:move) { |**kw| calls << [ :move, kw ] }
    fake_mouse.define_singleton_method(:down) { |**kw| calls << [ :down, kw ] }
    fake_mouse.define_singleton_method(:up) { |**kw| calls << [ :up, kw ] }
    fake_page = Object.new
    fake_page.define_singleton_method(:mouse) { fake_mouse }
    record = {
      "session_id" => "s-drag", "provider" => "wechat_mp", "port" => 1, "pid" => 1,
      "created_at" => Time.current.iso8601, "last_activity_at" => Time.current.iso8601
    }

    with_memory_cache do
      Rails.cache.write("browser_login:session:s-drag", record)

      stub_class_method(BrowserLogin::Session, :with_page, ->(_record, &block) { block.call(fake_page) }) do
        BrowserLogin::Session.interact("s-drag", type: "mousedown", x: 100, y: 200)
        BrowserLogin::Session.interact("s-drag", type: "mousemove", x: 160, y: 200)
        BrowserLogin::Session.interact("s-drag", type: "mousemove", x: 220, y: 200)
        BrowserLogin::Session.interact("s-drag", type: "mouseup", x: 220, y: 200)
      end
    end

    assert_equal [
      [ :move, { x: 100.0, y: 200.0 } ],
      [ :down, { button: :left } ],
      [ :move, { x: 160.0, y: 200.0 } ],
      [ :move, { x: 220.0, y: 200.0 } ],
      [ :up, { button: :left } ]
    ], calls
  end

  # ── 启动参数：UA 归一化与代理（BrowserLogin::Launcher）──

  # 实测：headless 的 UA 带 HeadlessChrome 字样，小红书风控直接据此拦截登录
  # （报 300012「IP 存在风险」），换正常 Chrome UA 后同一网络同一浏览器放行。
  test "headless launch args normalize the user agent" do
    stub_class_method(BrowserLogin::Launcher, :chrome_binary, -> { "/usr/bin/chromium" }) do
      args = BrowserLogin::Launcher.args(
        profile_dir: "/tmp/profile", port: 9222,
        url: BrowserLogin::WechatMp.login_url, headless_flag: "--headless=new"
      )

      assert_includes args, "--headless=new"
      ua = args.find { |a| a.start_with?("--user-agent=") }
      assert ua.present?, "headless 模式必须覆盖 UA"
      assert_not_includes ua, "Headless"
      assert_match(/Chrome\/\d+\.\d+\.0\.0 Safari\/537\.36\z/, ua.delete_prefix("--user-agent="))
      assert_includes args, "--disable-blink-features=AutomationControlled"
      assert_not args.any? { |a| a.start_with?("--proxy-server=") }, "未配置代理时必须直连"
      assert_equal BrowserLogin::WechatMp.login_url, args.last, "登录页必须是最后一个参数"
    end
  end

  test "headed launch args carry no headless flag or UA override" do
    stub_class_method(BrowserLogin::Launcher, :chrome_binary, -> { "/usr/bin/chromium" }) do
      args = BrowserLogin::Launcher.args(
        profile_dir: "/tmp/profile", port: 9222,
        url: BrowserLogin::WechatMp.login_url, headless_flag: nil
      )

      assert_not args.any? { |a| a.start_with?("--headless") }
      assert_not args.any? { |a| a.start_with?("--user-agent=") }, "有界面模式的 UA 本来就正常，不应覆盖"
    end
  end

  test "launch args pass the configured proxy to Chrome" do
    Option.browser_login_proxy = "http://127.0.0.1:7890"
    stub_class_method(BrowserLogin::Launcher, :chrome_binary, -> { "/usr/bin/chromium" }) do
      args = BrowserLogin::Launcher.args(
        profile_dir: "/tmp/profile", port: 9222,
        url: "https://mp.weixin.qq.com/", headless_flag: "--headless"
      )

      assert_includes args, "--proxy-server=http://127.0.0.1:7890"
    end
  ensure
    Option.browser_login_proxy = nil
  end

  test "normalized user agent never advertises headless" do
    ua = BrowserLogin::Launcher.normalized_user_agent

    assert_not_includes ua, "Headless"
    assert_match(/\AMozilla\/5\.0 \(X11; Linux x86_64\) AppleWebKit\/537\.36 \(KHTML, like Gecko\) Chrome\/\d+\.\d+\.0\.0 Safari\/537\.36\z/, ua)
  end

  # ── 风控提示 ──────────────────────────────────────────

  test "rednote risk hint fires on the 300012 page text" do
    page = FakePage.new(url: "https://www.xiaohongshu.com/", html: "当前IP存在风险，请切换到安全网络后重试 (300012)")

    hint = BrowserLogin::RednoteWeb.risk_hint(page)

    assert hint.present?
    assert_match(/代理/, hint)
  end

  test "rednote risk hint stays quiet on a normal page" do
    page = FakePage.new(url: "https://www.xiaohongshu.com/", html: "小红书，你的生活指南")

    assert_nil BrowserLogin::RednoteWeb.risk_hint(page)
  end

  test "frame surfaces the risk hint in its message" do
    fake_page = Object.new
    fake_page.define_singleton_method(:cookies) { Struct.new(:all).new({}) }
    fake_page.define_singleton_method(:screenshot) { |**| "QUJD" }
    fake_page.define_singleton_method(:url) { "https://www.xiaohongshu.com/" }
    fake_page.define_singleton_method(:evaluate) { |_js| "IP 存在风险 300012" }

    record = {
      "session_id" => "s-risk", "provider" => "rednote_web", "port" => 1, "pid" => 1,
      "created_at" => Time.current.iso8601, "last_activity_at" => Time.current.iso8601
    }

    with_memory_cache do
      Rails.cache.write("browser_login:session:s-risk", record)

      stub_class_method(BrowserLogin::Session, :with_page, ->(_record, &block) { block.call(fake_page) }) do
        result = BrowserLogin::Session.frame("s-risk")

        assert_match(/300012/, result[:message])
        assert_match(/代理/, result[:message])
      end
    end
  end

  # 截图是视口截图：没有 DISPLAY 时 Chrome 的窗口可能只有几十像素高，
  # 不钉住视口则前端只能看到一条细缝、点击坐标也无从换算（真机实测踩到过）。
  test "frame pins the CDP viewport before screenshotting" do
    commands = []
    fake_page = Object.new
    fake_page.define_singleton_method(:command) { |name, **params| commands << [ name, params ]; {} }
    fake_page.define_singleton_method(:cookies) { Struct.new(:all).new({}) }
    fake_page.define_singleton_method(:screenshot) { |**| "QUJD" }
    fake_page.define_singleton_method(:url) { "https://mp.weixin.qq.com/" }
    fake_browser = Object.new
    fake_browser.define_singleton_method(:pages) { [ fake_page ] }

    record = {
      "session_id" => "s-viewport", "provider" => "wechat_mp", "port" => 1, "pid" => 1,
      "created_at" => Time.current.iso8601, "last_activity_at" => Time.current.iso8601
    }

    with_memory_cache do
      Rails.cache.write("browser_login:session:s-viewport", record)

      stub_class_method(Ferrum::Browser, :new, ->(**_) { fake_browser }) do
        result = BrowserLogin::Session.frame("s-viewport")
        assert_equal "QUJD", result[:image]
      end
    end

    pin = commands.find { |name, _| name == "Emulation.setDeviceMetricsOverride" }
    assert pin, "截图前必须固定视口尺寸"
    assert_equal BrowserLogin::Session::VIEWPORT[:width], pin[1][:width]
    assert_equal BrowserLogin::Session::VIEWPORT[:height], pin[1][:height]
  end

  # ── Cookie 快照 ──────────────────────────────────────
  # 会话级 Cookie（微信环境验证、slave_sid）Chrome 不会写进 profile，浏览器
  # 进程退出即丢；Session#frame 必须持续把它们导出到 profile 目录，供正文
  # 下载的独立浏览器回灌（生产踩过：验证完一结束会话，下载又被拦）。

  # CookieExport.serialize 需要的 Ferrum cookie 替身（to_h 返回 CDP 字符串键）
  SnapshotCookie = Struct.new(:name, :value, :domain, :path, :expires, :httpOnly, :secure, :sameSite) do
    def to_h
      { "name" => name, "value" => value, "domain" => domain, "path" => path,
        "expires" => expires, "httpOnly" => httpOnly, "secure" => secure, "sameSite" => sameSite }
    end
  end

  test "frame snapshots provider-scoped cookies into the profile dir" do
    Dir.mktmpdir do |tmp_root|
      profile_dir = File.join(tmp_root, "wechat_mp")
      wechat = SnapshotCookie.new("slave_sid", "s", ".qq.com", "/", 0, true, true, "Lax")
      junk = SnapshotCookie.new("junk", "j", ".example.com", "/", 0, false, false, nil)
      fake_page = Object.new
      fake_page.define_singleton_method(:cookies) { Struct.new(:all).new({ "slave_sid" => wechat, "junk" => junk }) }
      fake_page.define_singleton_method(:screenshot) { |**| "QUJD" }
      fake_page.define_singleton_method(:url) { "https://mp.weixin.qq.com/" }

      record = {
        "session_id" => "s-snap", "provider" => "wechat_mp", "port" => 1, "pid" => 1,
        "created_at" => Time.current.iso8601, "last_activity_at" => Time.current.iso8601
      }

      with_memory_cache do
        Rails.cache.write("browser_login:session:s-snap", record)

        stub_class_method(BrowserLogin, :profile_dir_for, ->(_key) { profile_dir }) do
          stub_class_method(BrowserLogin::Session, :with_page, ->(_record, &block) { block.call(fake_page) }) do
            result = BrowserLogin::Session.frame("s-snap")
            assert_equal "QUJD", result[:image], "快照失败不得影响截图主流程"
          end
        end
      end

      entries = JSON.parse(File.read(BrowserLogin::CookieExport.path_for(profile_dir)))
      assert_equal [ "slave_sid" ], entries.map { |e| e["name"] }, "快照只保留平台域 Cookie"
    end
  end

  test "orphan_record adopts a live browser from the pid flag file when cache is gone" do
    Dir.mktmpdir do |tmp_root|
      profile_dir = File.join(tmp_root, "wechat_mp")
      FileUtils.mkdir_p(profile_dir)
      flag_file = File.join(profile_dir, BrowserLogin::Session::PROFILE_FLAG_FILE)
      File.write(flag_file, { "port" => 4100, "pid" => 424242, "xvfb_pid" => nil }.to_json)

      stub_class_method(BrowserLogin, :profile_dir_for, ->(_key) { profile_dir }) do
        stub_class_method(BrowserLogin::Launcher, :process_alive?, ->(_pid) { true }) do
          stub_class_method(BrowserLogin::Launcher, :cdp_ready?, ->(_port) { true }) do
            record = BrowserLogin::Session.orphan_record("wechat_mp")

            assert_equal 4100, record["port"]
            assert_equal 424242, record["pid"]
            assert record["orphan"], "供正文抓取附着的孤儿记录"
          end
        end

        stub_class_method(BrowserLogin::Launcher, :process_alive?, ->(_pid) { false }) do
          assert_nil BrowserLogin::Session.orphan_record("wechat_mp"), "进程已死不得收养"
        end
      end

      File.delete(flag_file)
      assert_nil BrowserLogin::Session.orphan_record("wechat_mp"), "无 flag 文件时返回 nil"
    end
  end

  # ── 进程组优雅退出 ────────────────────────────────────
  # Chrome 退出时会 flush Cookie 并写完 profile；TERM 后立刻 SIGKILL 会截断
  # 落盘甚至损坏 profile，必须先等进程退出（生产踩过：验证 Cookie 没落盘）。

  test "kill_process_tree lets a cooperative process exit gracefully" do
    pid = ::Process.spawn("sleep", "30", pgroup: true)
    ::Process.detach(pid)

    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    BrowserLogin::Launcher.kill_process_tree(pid, graceful_timeout: 8)
    elapsed = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started

    sleep(0.3) # 等 detach 的 reaper 收尸，避免僵尸进程被误判为存活
    assert_not BrowserLogin::Launcher.process_alive?(pid)
    assert_operator elapsed, :<, 3, "配合 TERM 的进程应立即退出，而不是等满超时"
  end

  test "kill_process_tree escalates to KILL when the process ignores TERM" do
    reader, writer = IO.pipe
    pid = ::Process.spawn(RbConfig.ruby, "-e", "trap('TERM', 'IGNORE'); puts 'ready'; $stdout.flush; sleep 30",
                          pgroup: true, out: writer, err: File::NULL)
    ::Process.detach(pid)
    writer.close
    reader.gets # 等子进程装好 trap 再发信号，否则 TERM 会落在 trap 生效前
    reader.close

    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    BrowserLogin::Launcher.kill_process_tree(pid, graceful_timeout: 1)
    elapsed = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started

    sleep(0.3)
    assert_not BrowserLogin::Launcher.process_alive?(pid)
    assert_operator elapsed, :>=, 1, "必须先等满优雅超时才升级 KILL"
  end

  # ── ProfileLock 与 Session 锁生命周期 ─────────────────

  test "profile lock excludes a second holder and releases cleanly" do
    Dir.mktmpdir do |dir|
      lock = BrowserLogin::ProfileLock.acquire(dir, timeout: 0)

      assert_raises(BrowserLogin::Error) { BrowserLogin::ProfileLock.acquire(dir, timeout: 0) }

      lock.release
      second = BrowserLogin::ProfileLock.acquire(dir, timeout: 0)
      second.release
    end
  end

  test "session holds the profile lock while alive and releases it on stop" do
    Dir.mktmpdir do |tmp_root|
      profile_dir = File.join(tmp_root, "wechat_mp")
      fake_page = Object.new
      fake_page.define_singleton_method(:url) { BrowserLogin::WechatMp.login_url }
      fake_browser = Object.new
      fake_browser.define_singleton_method(:pages) { [ fake_page ] }

      stub_class_method(BrowserLogin, :profile_dir_for, ->(_key) { profile_dir }) do
        stub_class_method(BrowserLogin::Launcher, :launch,
                          ->(profile_dir:, url:, headed:) { [ 4002, 424242, nil ] }) do
          stub_class_method(BrowserLogin::Launcher, :cdp_ready?, ->(_port) { true }) do
            stub_class_method(BrowserLogin::Launcher, :attach, ->(_port) { fake_browser }) do
              stub_class_method(BrowserLogin::Launcher, :pin_viewport, ->(_page) { nil }) do
                stub_class_method(BrowserLogin::Launcher, :kill_process_tree, ->(_pid) { nil }) do
                  stub_class_method(BrowserLogin::Launcher, :kill_process, ->(_pid) { nil }) do
                    with_memory_cache do
                      result = BrowserLogin::Session.start("wechat_mp")
                      assert_not result[:resumed]

                      error = assert_raises(BrowserLogin::Error) do
                        BrowserLogin::ProfileLock.acquire(profile_dir, timeout: 0)
                      end
                      assert_match(/占用/, error.message)

                      BrowserLogin::Session.stop(result[:session_id])
                      lock = BrowserLogin::ProfileLock.acquire(profile_dir, timeout: 0)
                      lock.release
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
