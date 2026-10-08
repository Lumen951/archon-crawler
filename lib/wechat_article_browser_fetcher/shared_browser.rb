# 正文抓取的常驻共享浏览器：WechatArticleBrowserFetcher 兜底路径的浏览器
# 生命周期管理。
#
# 为什么常驻：环境验证拦截是逐篇兜底的，原先每篇拉起一个完整 Chrome（启动
# 2~5s、回灌快照、用完即杀），一批下来既慢又制造大量僵尸子进程。这里改成
# 进程内单例：第一次兜底时拉起，之后复用同一个 Chrome 与 ferrum 连接（全程
# 一条 WS + 两个线程），空闲超过 IDLE_TTL 后在下次抓取时惰性回收。
#
# 跨进程所有权（日常下载 job 跑在 Solid Queue 进程，文章页「重新下载」跑在
# web 请求进程，两边都可能进入兜底）：
#   - owner 持有 PROFILE_PROVIDER 目录的 ProfileLock（flock）直到浏览器被
#     回收，并把 port/pid 落盘 pid 文件；
#   - 其他进程拿不到锁时按 pid 文件借用附着：只开标签页抓完即断开，不拉起、
#     不杀进程，浏览器的生死归 owner 管；
#   - owner 进程死亡后 flock 随之释放，Chrome 成为孤儿存活，下一个抓取进程
#     凭 pid 文件收养，避免再拉一个被 SingletonLock 顶掉的同 profile Chrome。
#
# 与登录浏览器（BrowserLogin::Session，weread_native profile）互不干扰：抓取
# 浏览器用独立 user-data-dir（终身持锁不能占用登录目录，否则挡住人工验证），
# Cookie 仍从登录 profile 的快照文件回灌（Session#frame 持续导出，含会话级
# 环境验证 Cookie），且每次抓取前重灌，长寿命浏览器因此能继承最新验证成果。
#
# 线程模型：类方法只在 WechatArticleBrowserFetcher 的串行 Mutex 内被 fetch
# 调用，@instance 不需要额外的锁。
class WechatArticleBrowserFetcher
  class SharedBrowser
    # 空闲多久后回收。下次抓取时惰性检查，回收前 Chrome 常驻内存。
    IDLE_TTL = 15.minutes
    # 抓取浏览器自己的 user-data-dir 与锁命名空间。不能直接用登录 profile 目录：
    # 登录浏览器会终身持有该目录的 ProfileLock，抓取浏览器若占住它，用户就打不开
    # 远程登录浏览器去完成验证/重新扫码了。
    PROFILE_PROVIDER = "wechat_mp_downloader"
    # Cookie 快照读登录浏览器的 profile 目录。远程浏览器里唯一还在承载微信侧
    # 人工验证的是微信读书直连（weread_native），其 cookie_domain_pattern 覆盖
    # qq.com，mp.weixin.qq.com 的环境验证 Cookie 因此也在快照里。
    SNAPSHOT_PROVIDER = "weread_native"
    PID_FILE = ".shared_browser.json"

    class << self
      # 在共享（或借用的）浏览器上开新标签页执行块，抓完关页。浏览器级失败
      # 抛 WechatArticleBrowserFetcher::Error；块内 CaptchaRequiredError /
      # DownloadError 原样穿透。
      def with_page(crawl_task)
        instance = acquire(crawl_task)
        page = instance.open_page(crawl_task)
        yield page
      ensure
        quietly { page&.close }
        instance&.after_use
      end

      # 回收本进程持有的共享浏览器（空闲 TTL 命中、不健康重生、测试复位）。
      def shutdown
        @instance&.kill
        @instance = nil
      end

      private

      def acquire(crawl_task)
        if @instance && !@instance.healthy?
          WechatCrawler.log(crawl_task, :info, "共享浏览器不可用（#{@instance.unhealthy_reason}），重新拉起")
          @instance.kill
          @instance = nil
        end
        return @instance if @instance

        @instance = acquire_ownership(crawl_task)
        return @instance if @instance

        borrow(crawl_task) or
          raise Error, "浏览器抓取失败：浏览器环境正被其他进程占用，且没有可借用的浏览器"
      end

      # 拿 profile 锁成为 owner；拿不到（其他进程持有存活浏览器）返回 nil 走借用。
      def acquire_ownership(crawl_task)
        lock = BrowserLogin::ProfileLock.acquire(profile_dir, timeout: 5)
        adopt(lock, crawl_task) || launch(lock, crawl_task)
      rescue BrowserLogin::Error
        nil
      end

      # 上一任 owner 进程死亡后（flock 已释放）Chrome 孤儿存活：凭 pid 文件
      # 附着收养，浏览器内存里的验证 Cookie 因此得以继承。
      def adopt(lock, crawl_task)
        data = read_pid_file
        return nil unless data

        unless BrowserLogin::Launcher.process_alive?(data["pid"]) &&
               BrowserLogin::Launcher.cdp_ready?(data["port"])
          quietly { pid_file.delete }
          return nil
        end

        browser = BrowserLogin::Launcher.attach(data["port"])
        WechatCrawler.log(crawl_task, :info, "收养上一任进程遗留的共享浏览器（pid=#{data["pid"]}）")
        new(browser: browser, port: data["port"], pid: data["pid"], xvfb_pid: data["xvfb_pid"],
            lock: lock, profile_dir: profile_dir, borrowed: false)
      rescue Ferrum::Error, IOError
        # pid 文件显示存活但附着失败（CDP 僵死等）：锁在手里，安全杀掉重拉
        if data && BrowserLogin::Launcher.process_matches?(data["pid"], profile_dir)
          BrowserLogin::Launcher.kill_process_tree(data["pid"])
        end
        quietly { pid_file.delete }
        nil
      end

      def launch(lock, crawl_task)
        pid = nil
        xvfb_pid = nil
        headed = Option.browser_login_headed?
        # 有界面模式与登录浏览器保持同一指纹（UA/窗口），避免「登录时有界面
        # 通过验证、抓取时 headless 又被拦」的不一致
        BrowserLogin::Launcher.clear_stale_chrome_locks(profile_dir)
        port, pid, xvfb_pid = BrowserLogin::Launcher.launch(
          profile_dir: profile_dir, url: "about:blank", headed: headed
        )
        browser = BrowserLogin::Launcher.attach(port)
        WechatCrawler.log(crawl_task, :info, "拉起共享抓取浏览器（pid=#{pid}）")
        instance = new(browser: browser, port: port, pid: pid, xvfb_pid: xvfb_pid,
                       lock: lock, profile_dir: profile_dir, borrowed: false)
        persist_pid_file(instance)
        instance
      rescue Ferrum::Error, IOError, BrowserLogin::Error => e
        BrowserLogin::Launcher.kill_process_tree(pid) if pid
        BrowserLogin::Launcher.kill_process(xvfb_pid) if xvfb_pid
        lock.release
        raise Error, "浏览器抓取失败：#{e.class}: #{e.message}"
      end

      # 锁被其他进程持有：按 pid 文件借用附着一次（开标签页抓完即断开）。
      def borrow(crawl_task)
        data = read_pid_file
        return nil unless data &&
                          BrowserLogin::Launcher.process_alive?(data["pid"]) &&
                          BrowserLogin::Launcher.cdp_ready?(data["port"])

        browser = BrowserLogin::Launcher.attach(data["port"])
        WechatCrawler.log(crawl_task, :info, "借用其他进程的共享浏览器（pid=#{data["pid"]}）")
        new(browser: browser, port: data["port"], pid: data["pid"], xvfb_pid: data["xvfb_pid"],
            lock: nil, profile_dir: profile_dir, borrowed: true)
      rescue Ferrum::Error, IOError => e
        raise Error, "浏览器抓取失败：借用浏览器连接失败：#{e.class}: #{e.message}"
      end

      def persist_pid_file(instance)
        pid_file.write({
          "port" => instance.port,
          "pid" => instance.pid,
          "xvfb_pid" => instance.xvfb_pid,
          "updated_at" => Time.current.iso8601
        }.to_json)
      end

      def read_pid_file
        JSON.parse(pid_file.read)
      rescue Errno::ENOENT, JSON::ParserError, StandardError
        nil
      end

      def profile_dir
        BrowserLogin.profile_dir_for(PROFILE_PROVIDER)
      end

      def pid_file
        Pathname.new(profile_dir) / PID_FILE
      end

      def quietly
        yield
      rescue StandardError
        nil
      end
    end

    attr_reader :port, :pid, :xvfb_pid

    def initialize(browser:, port:, pid:, xvfb_pid:, lock:, profile_dir:, borrowed:)
      @browser = browser
      @port = port
      @pid = pid
      @xvfb_pid = xvfb_pid
      @lock = lock
      @profile_dir = profile_dir
      @borrowed = borrowed
      @fingerprint = current_fingerprint
      @last_used_at = Time.current
    end

    # 每次抓取一个新标签页：先回灌最新 Cookie 快照再交给调用方导航，页面间
    # 状态隔离。
    def open_page(crawl_task)
      page = @browser.create_page
      BrowserLogin::Launcher.pin_viewport(page)
      restore_cookies!(page, crawl_task)
      page
    rescue Ferrum::Error, IOError => e
      raise Error, "浏览器抓取失败：#{e.class}: #{e.message}"
    end

    def after_use
      @last_used_at = Time.current
      return unless @borrowed

      # 借用的连接一次性使用：只断开 CDP（attach 模式 quit 不碰浏览器进程）
      quietly { @browser.quit }
    end

    def healthy?
      @unhealthy_reason =
        if idle_expired?
          "空闲超时"
        elsif @fingerprint != current_fingerprint
          "启动参数已变化"
        elsif !browser_reachable?
          "浏览器进程或 CDP 不可达"
        end
      @unhealthy_reason.nil?
    end

    def unhealthy_reason
      @unhealthy_reason
    end

    # 回收：先 quit 释放 ferrum 线程（Chrome 被杀只是断 WS，线程不会自己退
    # 出），再按 cmdline 核对后杀进程树（防 pid 复用误杀，同
    # BrowserLogin::Session#destroy），最后清 pid 文件、交回 profile 锁。
    def kill
      quietly { @browser.quit }
      if BrowserLogin::Launcher.process_matches?(@pid, @profile_dir)
        BrowserLogin::Launcher.kill_process_tree(@pid)
      else
        WechatCrawler.log(nil, :info, "共享浏览器 pid #{@pid} 已不是原进程，跳过杀进程")
      end
      if @xvfb_pid && BrowserLogin::Launcher.process_matches?(@xvfb_pid, "Xvfb")
        BrowserLogin::Launcher.kill_process(@xvfb_pid)
      end
      quietly { pid_path.delete }
      @lock&.release
    end

    private

    def idle_expired?
      @last_used_at < IDLE_TTL.ago
    end

    def current_fingerprint
      [ Option.browser_login_headed? ? "headed" : "headless", Option.browser_login_proxy.presence ].join("|")
    end

    def browser_reachable?
      return false unless BrowserLogin::Launcher.process_alive?(@pid)
      return false unless BrowserLogin::Launcher.process_matches?(@pid, @profile_dir)
      return false unless BrowserLogin::Launcher.cdp_ready?(@port)

      @browser.pages # ferrum 连接存活探测（进程活着但 WS 已死的情况）
      true
    rescue Ferrum::Error, IOError
      false
    end

    # 会话级 Cookie（环境验证、登录态）Chrome 不会写进 profile，必须从登录
    # 浏览器目录的快照回灌（weread_native profile：人工环境验证留在那里）；
    # 每次抓取都重灌，单条失败不影响其余。
    def restore_cookies!(page, crawl_task)
      snapshot_dir = BrowserLogin.profile_dir_for(SNAPSHOT_PROVIDER)
      entries = BrowserLogin::CookieExport.load(snapshot_dir)
      WechatCrawler.log(crawl_task, :info,
                        "读取 Cookie 快照：#{snapshot_dir}/#{BrowserLogin::CookieExport::FILENAME}（#{entries.size} 条）")
      return if entries.empty?

      restored = 0
      failures = Hash.new(0)
      entries.each do |entry|
        page.cookies.set(entry)
        restored += 1
      rescue StandardError => e
        failures[e.class.name] += 1
      end

      failure_summary = failures.map { |error, count| "#{error}=#{count}" }.join(", ")
      suffix = failure_summary.present? ? "，失败：#{failure_summary}" : ""
      WechatCrawler.log(crawl_task, :info, "Cookie 快照回灌结果：成功 #{restored}/#{entries.size} 条#{suffix}")
    end

    def pid_path
      Pathname.new(@profile_dir) / PID_FILE
    end

    def quietly
      yield
    rescue StandardError
      nil
    end
  end
end
