require "test_helper"

class WechatArticleBrowserFetcherTest < ActiveSupport::TestCase
  setup do
    Option.delete_all
    @article_url = "https://mp.weixin.qq.com/s?__biz=MzA=&mid=1&idx=1&sn=x"
    @captcha_url = "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?poc_token=abc&target_url=#{CGI.escape(@article_url)}#rd"
  end
  # 鸭子类型替身：WechatArticleBrowserFetcher 只用 go_to / url / body / close / cookies.set
  class FakeCookies
    attr_reader :sets

    def initialize = (@sets = [])

    def set(entry) = (@sets << entry)
  end

  class FakePage
    attr_reader :navigated_to, :closed, :cookie_sets

    def initialize(url:, body:)
      @url = url
      @body = body
      @closed = false
      @cookie_sets = FakeCookies.new
    end

    attr_writer :url

    def go_to(target)
      @navigated_to = target
      self
    end

    def url = @url

    def body = @body

    def cookies = @cookie_sets

    def close = @closed = true

    def command(*) = {}
  end

  class FakeBrowser
    def initialize(page)
      @page = page
    end

    def create_page = @page

    def pages = [ @page ]

    def quit = nil
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

  test "fetch keeps the deleted-content semantics of the http path" do
    page = FakePage.new(url: @article_url, body: "<html>该内容已被发布者删除</html>")

    assert_raises(WechatCrawler::DownloadError) do
      fetch_via_session(page, @article_url)
    end
  end

  test "fetch spawns a one-shot chrome and releases the profile lock when no session is active" do
    Dir.mktmpdir do |tmp_root|
      page = FakePage.new(url: @article_url, body: "<div id=\"js_content\">正文</div>")
      profile_dir = File.join(tmp_root, "wechat_mp")
      launched = {}
      killed = []
      FileUtils.mkdir_p(profile_dir)
      FileUtils.ln_s("old-container-host-123", File.join(profile_dir, "SingletonLock"))

      stub_class_method(BrowserLogin::Session, :active_record, ->(_key) { nil }) do
        stub_class_method(BrowserLogin, :profile_dir_for, ->(_key) { profile_dir }) do
          stub_class_method(BrowserLogin::Launcher, :launch,
                            ->(profile_dir:, url:, headed:) { launched[:url] = url; launched[:headed] = headed; [ 4001, 4242, nil ] }) do
            stub_class_method(BrowserLogin::Launcher, :attach, ->(_port) { FakeBrowser.new(page) }) do
              stub_class_method(BrowserLogin::Launcher, :kill_process_tree, ->(pid) { killed << pid }) do
                stub_class_method(BrowserLogin::Launcher, :kill_process, ->(pid) { killed << pid }) do
                  html = WechatArticleBrowserFetcher.fetch(@article_url)

                  assert_includes html, "正文"
                  assert_equal "about:blank", launched[:url], "一次性 Chrome 以空白页启动，由 go_to 显式导航"
                  assert_equal false, launched[:headed], "默认无界面模式"
                  assert_includes killed, 4242, "抓完必须杀掉一次性 Chrome"
                  assert_empty page.cookie_sets.sets, "没有快照时不应注入任何 Cookie"
                end
              end
            end
          end
        end
      end

      assert_not File.exist?(File.join(profile_dir, "SingletonLock")), "spawn 前必须清掉跨容器残锁"

      # 锁已释放：能再次获取
      lock = BrowserLogin::ProfileLock.acquire(profile_dir, timeout: 0)
      lock.release
    end
  end

  # 会话级 Cookie（环境验证、登录态）Chrome 不会写进 profile：独立浏览器必须
  # 先回灌 Session#frame 导出的快照，否则人工验证成果继承不到（生产踩过）。
  test "spawned browser restores the cookie snapshot before navigating" do
    Dir.mktmpdir do |tmp_root|
      page = FakePage.new(url: @article_url, body: "<div id=\"js_content\">正文</div>")
      profile_dir = File.join(tmp_root, "wechat_mp")
      FileUtils.mkdir_p(profile_dir)
      json = BrowserLogin::CookieExport.serialize(
        [ SnapshotCookie.new("slave_sid", "s", ".qq.com", "/", 0, true, true, nil) ]
      )
      BrowserLogin::CookieExport.save(profile_dir, json)

      stub_class_method(BrowserLogin::Session, :active_record, ->(_key) { nil }) do
        stub_class_method(BrowserLogin, :profile_dir_for, ->(_key) { profile_dir }) do
          stub_class_method(BrowserLogin::Launcher, :launch, ->(profile_dir:, url:, headed:) { [ 4001, 4242, nil ] }) do
            stub_class_method(BrowserLogin::Launcher, :attach, ->(_port) { FakeBrowser.new(page) }) do
              stub_class_method(BrowserLogin::Launcher, :kill_process_tree, ->(pid) { nil }) do
                stub_class_method(BrowserLogin::Launcher, :kill_process, ->(pid) { nil }) do
                  html = WechatArticleBrowserFetcher.fetch(@article_url)

                  assert_includes html, "正文"
                  assert_equal [ {
                    "name" => "slave_sid", "value" => "s", "domain" => ".qq.com", "path" => "/",
                    "httpOnly" => true, "secure" => true
                  } ], page.cookie_sets.sets, "导航前必须回灌快照（会话级 Cookie 不带 expires）"
                end
              end
            end
          end
        end
      end
    end
  end

  test "spawned fetch browser follows the headed-mode option" do
    Option.browser_login_headed = true
    page = FakePage.new(url: @article_url, body: "正文")
    launched = {}

    Dir.mktmpdir do |tmp_root|
      profile_dir = File.join(tmp_root, "wechat_mp")

      stub_class_method(BrowserLogin::Session, :active_record, ->(_key) { nil }) do
        stub_class_method(BrowserLogin, :profile_dir_for, ->(_key) { profile_dir }) do
          stub_class_method(BrowserLogin::Launcher, :launch,
                            ->(profile_dir:, url:, headed:) { launched[:headed] = headed; [ 4001, 4242, nil ] }) do
            stub_class_method(BrowserLogin::Launcher, :attach, ->(_port) { FakeBrowser.new(page) }) do
              stub_class_method(BrowserLogin::Launcher, :kill_process_tree, ->(pid) { nil }) do
                stub_class_method(BrowserLogin::Launcher, :kill_process, ->(pid) { nil }) do
                  WechatArticleBrowserFetcher.fetch(@article_url)

                  assert_equal true, launched[:headed], "有界面选项开启时独立浏览器应与登录浏览器同指纹"
                end
              end
            end
          end
        end
      end
    end
  ensure
    Option.browser_login_headed = false
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
end
