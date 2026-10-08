require "test_helper"

class WechatArticleBrowserFetcherTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    Option.delete_all
    # 类级限流器跨测试共享，放水避免滑动窗口拖慢套件
    Option.wechat_download_rate_limit = 1000
    # 上一条测试可能遗留常驻共享浏览器：垫掉杀进程后复位（防误杀机器上的真实 pid）
    stub_class_method(BrowserLogin::Launcher, :kill_process_tree, ->(_pid) { nil }) do
      stub_class_method(BrowserLogin::Launcher, :kill_process, ->(_pid) { nil }) do
        WechatArticleBrowserFetcher::SharedBrowser.shutdown
      end
    end
    @article_url = "https://mp.weixin.qq.com/s?__biz=MzA=&mid=1&idx=1&sn=x"
    @captcha_url = "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?poc_token=abc&target_url=#{CGI.escape(@article_url)}#rd"
  end

  # 鸭子类型替身：WechatArticleBrowserFetcher 只用 go_to / url / body / close /
  # cookies.set / quit
  class FakeCookies
    attr_reader :sets

    def initialize = (@sets = [])

    def set(entry) = (@sets << entry)
  end

  class FakePage
    attr_reader :navigated_to, :closed, :cookie_sets, :go_to_calls

    def initialize(url:, body:)
      @url = url
      @body = body
      @closed = false
      @cookie_sets = FakeCookies.new
    end

    attr_writer :url

    def go_to(target)
      @navigated_to = target
      @go_to_calls = @go_to_calls.to_i + 1
      self
    end

    def url = @url

    def body = @body

    def cookies = @cookie_sets

    def close = @closed = true

    def command(*) = {}
  end

  class FakeBrowser
    attr_reader :quit_called

    def initialize(page)
      @page = page
      @quit_called = false
    end

    def create_page = @page

    def pages = [ @page ]

    def quit = @quit_called = true
  end

  test "fetch navigates to the target_url when given a captcha redirect url" do
    page = FakePage.new(url: @article_url, body: "<div id=\"js_content\">正文</div>")

    assert_equal "<div id=\"js_content\">正文</div>", fetch_via_session(page, @captcha_url)
    assert_equal @article_url, page.navigated_to, "验证页链接应取 target_url 作为真实地址"
    assert page.closed, "附着会话抓取完后应关闭新开的标签页"
  end

  test "fetch returns the rendered body on success" do
    page = FakePage.new(url: @article_url, body: "<html><div id=\"js_content\">正文</div></html>")

    assert_includes fetch_via_session(page, @article_url), "正文"
  end

  test "fetch raises captcha error with guidance when still blocked in the browser" do
    page = FakePage.new(url: @article_url, body: "<html>当前环境异常，完成验证后即可继续访问。</html>")

    error = assert_raises(WechatArticleBrowserFetcher::CaptchaRequiredError) do
      fetch_via_session(page, @article_url)
    end

    # download_article_content 依赖这个字样识别平台级拦截并终止整批下载
    assert_match(/当前环境异常，需要验证/, error.message)
    assert_match(/远程浏览器登录/, error.message, "必须给出可操作的验证指引")
    assert_includes error.message, @article_url, "消息里必须带上可粘贴到地址栏的链接"
    assert page.closed
  end

  test "fetch raises captcha error when the page is the captcha url itself" do
    page = FakePage.new(url: @captcha_url, body: "<html>验证</html>")

    assert_raises(WechatArticleBrowserFetcher::CaptchaRequiredError) do
      fetch_via_session(page, @article_url)
    end
  end

  # 回归守卫：远程浏览器里唯一还在承载微信侧人工验证的平台是微信读书直连
  # （weread_native）。Cookie 桥的两端都必须指向它——指错了就永远继承不到人工
  # 验证成果（生产踩过：指向已从设置页下线的 wechat_mp，快照停留 9 天前的版本，
  # 于是正文下载一直卡在「当前环境异常」）。
  test "the cookie bridge targets the profile that carries the manual verification" do
    assert_equal "weread_native", WechatArticleBrowserFetcher::PROFILE_PROVIDER
    assert_equal "weread_native", WechatArticleBrowserFetcher::SharedBrowser::SNAPSHOT_PROVIDER
    assert_includes BrowserLogin::PROVIDERS.keys, WechatArticleBrowserFetcher::PROFILE_PROVIDER,
                    "附着登录浏览器用的 platform key 必须是远程浏览器登录里的真实平台"
  end

  # 快照按 provider 的 cookie_domain_pattern 过滤，该 pattern 必须覆盖
  # mp.weixin.qq.com，否则人工通过的环境验证 Cookie 根本进不了快照。
  test "weread_native snapshot covers the mp.weixin.qq.com verification cookies" do
    pattern = BrowserLogin.find("weread_native").cookie_domain_pattern

    assert_match pattern, "mp.weixin.qq.com"
    assert_match pattern, ".weixin.qq.com"
    assert_match pattern, "weread.qq.com"
  end

  test "fetch keeps the deleted-content semantics of the http path" do
    page = FakePage.new(url: @article_url, body: "<html>该内容已被发布者删除</html>")

    assert_raises(WechatCrawler::DownloadError) do
      fetch_via_session(page, @article_url)
    end
  end

  # 会话级 Cookie（环境验证、登录态）Chrome 不会写进 profile：独立浏览器必须
  # 先回灌 Session#frame 导出的快照，否则人工验证成果继承不到（生产踩过）。
  test "shared browser re-injects the latest cookie snapshot before every fetch" do
    Dir.mktmpdir do |tmp_root|
      page = FakePage.new(url: @article_url, body: "<div id=\"js_content\">正文</div>")
      browser = FakeBrowser.new(page)
      profile_dir = File.join(tmp_root, "wechat_mp_downloader")
      snapshot_dir = File.join(tmp_root, "weread_native")
      FileUtils.mkdir_p(snapshot_dir)
      write_snapshot(snapshot_dir, "s1")

      without_session(profile_dir, snapshot_dir: snapshot_dir) do
        stub_launch do
          stub_attach(->(_port) { browser }) do
            with_kill_stubs([]) do
              WechatArticleBrowserFetcher.fetch(@article_url)

              # 模拟登录浏览器里完成了新一轮环境验证：快照值更新
              write_snapshot(snapshot_dir, "s2")

              WechatArticleBrowserFetcher.fetch(@article_url)

              assert_equal %w[s1 s2], page.cookie_sets.sets.map { |entry| entry["value"] },
                           "每次抓取前都要重灌最新快照，长寿命浏览器才能继承新验证"
            end
          end
        end
      end
    end
  end

  # 常驻共享浏览器的核心语义：跨抓取复用同一 Chrome 与 ferrum 连接，浏览器
  # 存活期间持有 profile 锁并落盘 pid 文件，shutdown 回收时先 quit 再杀进程。
  test "fetch reuses one shared browser across fetches and keeps the profile lock until shutdown" do
    Dir.mktmpdir do |tmp_root|
      page = FakePage.new(url: @article_url, body: "<div id=\"js_content\">正文</div>")
      browser = FakeBrowser.new(page)
      profile_dir = File.join(tmp_root, "wechat_mp_downloader")
      launched = []
      attached_ports = []
      killed = []
      quit_state_at_kill = []

      without_session(profile_dir) do
        stub_launch(->(profile_dir:, url:, headed:) { launched << { url: url, headed: headed }; [ 4001, 4242, nil ] }) do
          stub_attach(->(port) { attached_ports << port; browser }) do
            with_kill_stubs(killed, before_kill: -> { quit_state_at_kill << browser.quit_called }) do
              FileUtils.mkdir_p(profile_dir)
              FileUtils.ln_s("old-container-host-123", File.join(profile_dir, "SingletonLock"))

              html = WechatArticleBrowserFetcher.fetch(@article_url)

              assert_includes html, "正文"
              WechatArticleBrowserFetcher.fetch(@article_url)

              assert_equal [ { url: "about:blank", headed: false } ], launched,
                           "两次抓取只拉起一次 Chrome，以空白页启动、由 go_to 显式导航"
              assert_not File.exist?(File.join(profile_dir, "SingletonLock")), "拉起前必须清掉跨容器残锁"
              assert_equal [ 4001 ], attached_ports, "复用同一 ferrum 连接，不重复附着"
              assert_equal 2, page.go_to_calls, "每次抓取都独立导航"
              assert_equal 4242,
                           JSON.parse(File.read(File.join(profile_dir, WechatArticleBrowserFetcher::SharedBrowser::PID_FILE)))["pid"],
                           "port/pid 必须落盘供跨进程收养"
              # 浏览器存活期间必须持有 profile 锁
              assert_raises(BrowserLogin::Error) { BrowserLogin::ProfileLock.acquire(profile_dir, timeout: 0) }

              WechatArticleBrowserFetcher::SharedBrowser.shutdown
              assert_equal [ true ], quit_state_at_kill, "杀进程前必须先 quit 释放 ferrum 线程"
              assert_includes killed, 4242, "回收时必须杀掉 Chrome"
              assert_not File.exist?(File.join(profile_dir, WechatArticleBrowserFetcher::SharedBrowser::PID_FILE)),
                         "回收后必须清掉 pid 文件"
              lock = BrowserLogin::ProfileLock.acquire(profile_dir, timeout: 0)
              lock.release
            end
          end
        end
      end
    end
  end

  test "browser option changes (headed/proxy) relaunch the shared browser" do
    Dir.mktmpdir do |tmp_root|
      page = FakePage.new(url: @article_url, body: "正文")
      browser = FakeBrowser.new(page)
      profile_dir = File.join(tmp_root, "wechat_mp_downloader")
      launched = []
      killed = []

      without_session(profile_dir) do
        stub_launch(->(profile_dir:, url:, headed:) { launched << headed; [ 4001, 4242, nil ] }) do
          stub_attach(->(_port) { browser }) do
            with_kill_stubs(killed) do
              WechatArticleBrowserFetcher.fetch(@article_url)
              assert_equal [ false ], launched, "默认无界面模式"

              Option.browser_login_headed = true
              WechatArticleBrowserFetcher.fetch(@article_url)

              assert_equal [ false, true ], launched,
                           "headed 选项变化后必须重启共享浏览器（与登录浏览器保持同一指纹）"
              assert_includes killed, 4242, "旧浏览器必须先被回收"
            end
          end
        end
      end
    end
  ensure
    Option.browser_login_headed = false
  end

  test "idle shared browser is recycled after the TTL" do
    Dir.mktmpdir do |tmp_root|
      page = FakePage.new(url: @article_url, body: "正文")
      browser = FakeBrowser.new(page)
      profile_dir = File.join(tmp_root, "wechat_mp_downloader")
      launched = []
      killed = []

      without_session(profile_dir) do
        stub_launch(->(profile_dir:, url:, headed:) { launched << headed; [ 4001, 4242, nil ] }) do
          stub_attach(->(_port) { browser }) do
            with_kill_stubs(killed) do
              WechatArticleBrowserFetcher.fetch(@article_url)
              assert_empty killed, "TTL 内的后续抓取必须复用浏览器"

              travel_to WechatArticleBrowserFetcher::SharedBrowser::IDLE_TTL.from_now + 1.minute do
                WechatArticleBrowserFetcher.fetch(@article_url)
              end

              assert_equal [ false, false ], launched, "空闲超过 TTL 后必须回收重拉"
              assert_includes killed, 4242, "过期浏览器必须被杀掉"
            end
          end
        end
      end
    end
  end

  # 上一任 owner 进程死亡后（flock 随之释放）Chrome 孤儿存活：凭 pid 文件
  # 收养，避免再拉一个被 SingletonLock 顶掉的同 profile Chrome。
  test "adopt a surviving browser left behind by a dead owner process" do
    Dir.mktmpdir do |tmp_root|
      page = FakePage.new(url: @article_url, body: "正文")
      browser = FakeBrowser.new(page)
      profile_dir = File.join(tmp_root, "wechat_mp_downloader")
      FileUtils.mkdir_p(profile_dir)
      File.write(File.join(profile_dir, WechatArticleBrowserFetcher::SharedBrowser::PID_FILE),
                 { "port" => 4777, "pid" => 4242, "xvfb_pid" => nil }.to_json)
      launched = false
      attached_ports = []
      killed = []

      without_session(profile_dir) do
        stub_launch(->(*) { launched = true; [ 4001, 4242, nil ] }) do
          stub_attach(->(port) { attached_ports << port; browser }) do
            with_kill_stubs(killed) do
              html = WechatArticleBrowserFetcher.fetch(@article_url)

              assert_includes html, "正文"
              assert_not launched, "有存活遗留浏览器时不得再拉起"
              assert_equal [ 4777 ], attached_ports, "必须按 pid 文件附着收养"
              # 收养后本进程成为 owner，必须持有 profile 锁
              assert_raises(BrowserLogin::Error) { BrowserLogin::ProfileLock.acquire(profile_dir, timeout: 0) }

              WechatArticleBrowserFetcher::SharedBrowser.shutdown
              assert_includes killed, 4242
              assert_not File.exist?(File.join(profile_dir, WechatArticleBrowserFetcher::SharedBrowser::PID_FILE))
            end
          end
        end
      end
    end
  end

  # 锁被 owner 进程持有（如日常下载 job 与手动「重新下载」分属不同进程）：
  # 按 pid 文件借用附着，只开标签页抓完即断开，绝不拉起或杀进程。
  test "borrow the running browser from the owning process when the lock is busy" do
    Dir.mktmpdir do |tmp_root|
      page = FakePage.new(url: @article_url, body: "正文")
      profile_dir = File.join(tmp_root, "wechat_mp_downloader")
      FileUtils.mkdir_p(profile_dir)
      File.write(File.join(profile_dir, WechatArticleBrowserFetcher::SharedBrowser::PID_FILE),
                 { "port" => 4777, "pid" => 4242, "xvfb_pid" => nil }.to_json)
      holder = BrowserLogin::ProfileLock.acquire(profile_dir, timeout: 0)
      launched = false
      attached_ports = []
      browsers = []
      killed = []

      without_session(profile_dir) do
        stub_launch(->(*) { launched = true; [ 4001, 4242, nil ] }) do
          stub_attach(->(port) do
            attached_ports << port
            FakeBrowser.new(page).tap { |b| browsers << b }
          end) do
            with_kill_stubs(killed) do
              WechatArticleBrowserFetcher.fetch(@article_url)
              WechatArticleBrowserFetcher.fetch(@article_url)

              assert_not launched, "锁被占用时不得拉起自己的浏览器"
              assert_equal [ 4777, 4777 ], attached_ports, "借用是每次抓取重新附着、一次一断"
              assert browsers.first.quit_called, "借用连接用完即断开"
              assert_empty killed, "借用方绝不杀浏览器进程"
            end
          end
        end
      end
    ensure
      holder.release
    end
  end

  test "raises when the lock is busy and no browser is borrowable" do
    Dir.mktmpdir do |tmp_root|
      profile_dir = File.join(tmp_root, "wechat_mp_downloader")
      FileUtils.mkdir_p(profile_dir)
      holder = BrowserLogin::ProfileLock.acquire(profile_dir, timeout: 0)

      without_session(profile_dir) do
        stub_launch(->(*) { flunk("锁被占用且无可借用浏览器时不应拉起") }) do
          error = assert_raises(WechatArticleBrowserFetcher::Error) do
            WechatArticleBrowserFetcher.fetch(@article_url)
          end

          assert_match(/占用/, error.message)
        end
      end
    ensure
      holder.release
    end
  end

  test "relaunches the shared browser when its process died between fetches" do
    Dir.mktmpdir do |tmp_root|
      page = FakePage.new(url: @article_url, body: "正文")
      browser = FakeBrowser.new(page)
      profile_dir = File.join(tmp_root, "wechat_mp_downloader")
      launched = []
      killed = []
      chrome_alive = true

      without_session(profile_dir, alive: ->(_pid) { chrome_alive }) do
        stub_launch(->(profile_dir:, url:, headed:) { launched << headed; [ 4001, 4242, nil ] }) do
          stub_attach(->(_port) { browser }) do
            with_kill_stubs(killed) do
              WechatArticleBrowserFetcher.fetch(@article_url)
              assert_empty killed

              chrome_alive = false # 模拟 Chrome 被 OOM killer 杀掉
              WechatArticleBrowserFetcher.fetch(@article_url)

              assert_equal [ false, false ], launched, "进程死亡后必须重新拉起"
              assert_includes killed, 4242, "死亡实例必须被回收"
            end
          end
        end
      end
    end
  end

  # Rails.cache 过期但登录浏览器进程还活着（用户关掉设置页后超时前的窗口）：
  # 应附着孤儿浏览器继承内存里的 Cookie，而不是另起同 profile 的第二个 Chrome
  test "fetch attaches to an orphan login browser when the cache record is gone" do
    page = FakePage.new(url: @article_url, body: "<div id=\"js_content\">正文</div>")
    orphan = { "port" => 4001, "pid" => 4242, "orphan" => true }
    launched = false
    attached_to = nil

    stub_class_method(BrowserLogin::Session, :active_record, ->(_key) { nil }) do
      stub_class_method(BrowserLogin::Session, :orphan_record, ->(_key) { orphan }) do
        stub_class_method(BrowserLogin::Launcher, :launch, ->(*) { launched = true; [ 4009, 999, nil ] }) do
          stub_class_method(BrowserLogin::Launcher, :attach, ->(port) { attached_to = port; FakeBrowser.new(page) }) do
            html = WechatArticleBrowserFetcher.fetch(@article_url)

            assert_includes html, "正文"
            assert_equal 4001, attached_to, "必须附着到孤儿浏览器的调试端口"
            assert_not launched, "有存活孤儿浏览器时不得再拉起独立 Chrome"
            assert_equal @article_url, page.navigated_to
          end
        end
      end
    end
  end

  private

  # CookieExport.serialize 需要的 Ferrum cookie 替身（to_h 返回 CDP 字符串键）
  SnapshotCookie = Struct.new(:name, :value, :domain, :path, :expires, :httpOnly, :secure, :sameSite,
                              keyword_init: false) do
    def to_h
      { "name" => name, "value" => value, "domain" => domain, "path" => path,
        "expires" => expires, "httpOnly" => httpOnly, "secure" => secure, "sameSite" => sameSite }
    end
  end

  # 附着登录会话的路径：active_record 返回端口记录
  def fetch_via_session(page, url)
    record = { "port" => 4001, "pid" => 4242 }
    stub_class_method(BrowserLogin::Session, :active_record, ->(_key) { record }) do
      stub_class_method(BrowserLogin::Launcher, :attach, ->(_port) { FakeBrowser.new(page) }) do
        WechatArticleBrowserFetcher.fetch(url)
      end
    end
  end

  # 无登录会话时的共享浏览器兜底路径：垫掉 Session 记录，把 profile 目录
  # 按用途分派到临时目录（下载浏览器目录 / 登录快照目录互不干扰），健康探测
  # 按 alive 谓词处理（替身浏览器没有真实进程，默认存活）。
  # 注意 stub_class_methods 不支持嵌套打同一个方法，存活谓词只能从这里传。
  def without_session(profile_root, snapshot_dir: profile_root, alive: ->(_pid) { true })
    stub_class_method(BrowserLogin::Session, :active_record, ->(_key) { nil }) do
      stub_class_method(BrowserLogin::Session, :orphan_record, ->(_key) { nil }) do
        stub_class_method(BrowserLogin, :profile_dir_for,
                          ->(key) do
                            if key == WechatArticleBrowserFetcher::SharedBrowser::PROFILE_PROVIDER
                              profile_root
                            else
                              snapshot_dir
                            end
                          end) do
          stub_class_method(BrowserLogin::Launcher, :process_alive?, alive) do
            stub_class_method(BrowserLogin::Launcher, :cdp_ready?, ->(_port) { true }) do
              yield
            end
          end
        end
      end
    end
  end

  def stub_launch(launch = ->(profile_dir:, url:, headed:) { [ 4001, 4242, nil ] })
    stub_class_method(BrowserLogin::Launcher, :launch, launch) do
      yield
    end
  end

  def stub_attach(attach)
    stub_class_method(BrowserLogin::Launcher, :attach, attach) do
      yield
    end
  end

  # 杀进程路径统一垫掉（含 pid 复用核对），before_kill 用于断言 quit 时序
  def with_kill_stubs(killed, before_kill: nil)
    stub_class_method(BrowserLogin::Launcher, :process_matches?, ->(_pid, _pattern) { true }) do
      stub_class_method(BrowserLogin::Launcher, :kill_process_tree,
                        ->(pid) { before_kill&.call; killed << pid }) do
        stub_class_method(BrowserLogin::Launcher, :kill_process, ->(pid) { killed << pid }) do
          yield
        end
      end
    end
  end

  def write_snapshot(dir, value)
    BrowserLogin::CookieExport.save(
      dir,
      BrowserLogin::CookieExport.serialize([ SnapshotCookie.new("slave_sid", value, ".qq.com", "/", 0, true, true, nil) ])
    )
  end
end
