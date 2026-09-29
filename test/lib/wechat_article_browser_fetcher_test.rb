require "test_helper"

class WechatArticleBrowserFetcherTest < ActiveSupport::TestCase
  setup do
    Option.delete_all
    @article_url = "https://mp.weixin.qq.com/s?__biz=MzA=&mid=1&idx=1&sn=x"
    @captcha_url = "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?poc_token=abc&target_url=#{CGI.escape(@article_url)}#rd"
  end
  # 鸭子类型替身：WechatArticleBrowserFetcher 只用 go_to / url / body / close
  class FakePage
    attr_reader :navigated_to, :closed

    def initialize(url:, body:)
      @url = url
      @body = body
      @closed = false
    end

    attr_writer :url

    def go_to(target)
      @navigated_to = target
      self
    end

    def url = @url

    def body = @body

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
                  assert_equal false, launched[:headed]
                  assert_includes killed, 4242, "抓完必须杀掉一次性 Chrome"
                end
              end
            end
          end
        end
      end

      # 锁已释放：能再次获取
      lock = BrowserLogin::ProfileLock.acquire(profile_dir, timeout: 0)
      lock.release
    end
  end

  private

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
