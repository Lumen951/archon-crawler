require "ferrum"
require "net/http"

module BrowserLogin
  # Chrome 进程启动 / CDP 附着 / 清理的共享工具。
  #
  # 供 BrowserLogin::Session（人工登录的远程浏览器）与
  # WechatArticleBrowserFetcher（正文抓取）复用，保证两边使用同一套
  # 反检测参数（UA 归一化、AutomationControlled、代理）与进程管理约定。
  module Launcher
    VIEWPORT = { width: 1280, height: 800 }.freeze
    # 无界面模式的 headless 参数阶梯（新语法优先，旧 Chromium 降级，最后不带参数）
    HEADLESS_FLAG_LADDER = %w[--headless=new --headless].push(nil).freeze
    CDP_WAIT_TIMEOUT = 15

    module_function

    # 启动一个 Chrome。返回 [port, pid, xvfb_pid]；失败时自行清理已拉起的
    # 进程后抛 BrowserLogin::Error。headed 时自动拉起 Xvfb 虚拟显示。
    def launch(profile_dir:, url:, headed:)
      attempts = 0
      flag_ladder = headed ? [ nil ] : HEADLESS_FLAG_LADDER
      begin
        port = alloc_port
        pid = nil
        xvfb_pid = nil
        env = {}
        if headed
          xvfb_pid, display_id = spawn_xvfb
          env["DISPLAY"] = ":#{display_id}"
        end

        headless_flag = flag_ladder[[ attempts, flag_ladder.size - 1 ].min]
        args = args(profile_dir: profile_dir, port: port, url: url, headless_flag: headless_flag)

        pid = ::Process.spawn(env, *args, pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL)
        ::Process.detach(pid)
        raise BrowserLogin::Error, "Chrome 进程启动失败" unless process_alive?(pid)
        raise BrowserLogin::Error, "Chrome 调试端口未就绪" unless wait_for_cdp(port)

        [ port, pid, xvfb_pid ]
      rescue StandardError
        kill_process_tree(pid) if pid
        kill_process(xvfb_pid) if xvfb_pid
        attempts += 1
        retry if attempts < 3
        raise
      end
    end

    # 启动参数（纯函数，便于测试）。headless_flag 为 nil 表示有界面模式。
    def args(profile_dir:, port:, url:, headless_flag:)
      [
        chrome_binary,
        headless_flag,
        # headless 的 UA 自带 HeadlessChrome 字样，小红书等平台的风控直接据此
        # 拦截登录（实测报 300012「IP 存在风险」），必须换成正常 Chrome UA；
        # 有界面模式的 UA 本来就正常，无需覆盖。
        ("--user-agent=#{normalized_user_agent}" if headless_flag),
        ("--proxy-server=#{Option.browser_login_proxy}" if Option.browser_login_proxy.present?),
        "--user-data-dir=#{profile_dir}",
        "--remote-debugging-port=#{port}",
        "--remote-allow-origins=*",
        "--no-first-run", "--no-default-browser-check",
        "--disable-background-networking", "--disable-sync",
        "--disable-dev-shm-usage", "--disable-gpu",
        "--no-sandbox",
        # 去掉 navigator.webdriver 自动化标记（与 WebsiteCrawler 的 selenium 兜底一致）
        "--disable-blink-features=AutomationControlled",
        "--window-size=#{VIEWPORT[:width]},#{VIEWPORT[:height]}",
        "--lang=zh-CN",
        url
      ].compact
    end

    # 正常 Chrome 的 UA。版本号取本机 Chromium 的真实主版本，保持 UA 与
    # JS/ClientHint 指纹一致；探测失败时回退到一个常规版本号。
    def normalized_user_agent
      major = chrome_major_version.presence || "130"
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) " \
        "Chrome/#{major}.0.0.0 Safari/537.36"
    end

    # 附着到已运行的 Chrome（不 spawn、不管理其生命周期，quit 不会杀掉它）
    def attach(port)
      Ferrum::Browser.new(url: "http://127.0.0.1:#{port}", timeout: 15, process_timeout: 15)
    end

    # Chrome 刚启动时页面 target 可能尚未注册，短暂等待而不是新建标签页
    def first_page(browser)
      deadline = 2.seconds.from_now
      while Time.current < deadline
        pages = browser.pages
        return pages.first if pages.any?
        sleep(0.1)
      end
      browser.page
    end

    # 把页面视口钉到固定尺寸。截图是视口截图，而 Chrome 的窗口大小会受运行
    # 环境影响（没有 DISPLAY 时可能退化成一个几十像素高的窗口），不钉住的话
    # 前端只能看到一条细缝，点击坐标也无从换算。
    def pin_viewport(page)
      page.command("Emulation.setDeviceMetricsOverride",
                   width: VIEWPORT[:width], height: VIEWPORT[:height],
                   deviceScaleFactor: 1, mobile: false)
    end

    def cdp_ready?(port)
      http = Net::HTTP.new("127.0.0.1", port)
      http.open_timeout = 0.5
      http.read_timeout = 1
      response = http.get("/json/version")
      response.is_a?(Net::HTTPSuccess)
    rescue StandardError
      false
    end

    def wait_for_cdp(port)
      deadline = CDP_WAIT_TIMEOUT.seconds.from_now
      while Time.current < deadline
        return true if cdp_ready?(port)
        sleep(0.25)
      end
      false
    end

    # /proc/<pid>/cmdline 内容（参数以 NUL 分隔，这里转成空格）；非 Linux
    # 或进程已不存在时返回 nil
    def process_cmdline(pid)
      File.read("/proc/#{Integer(pid)}/cmdline").tr("\0", " ")
    rescue StandardError
      nil
    end

    # pid 是否仍是对应特征的那个进程（按命令行核对）。Rails.cache 与 pid
    # 文件会跨容器重启存留，新容器里同一 pid 数字可能属于任意进程，杀进程
    # 前必须核对，否则可能误伤容器里的其他进程（甚至 puma 自己）。
    # 拿不到 cmdline（非 Linux 环境）时无法核对，保持按 pid 处理的原行为。
    def process_matches?(pid, pattern)
      cmdline = process_cmdline(pid)
      return true if cmdline.nil?

      pattern.is_a?(Regexp) ? cmdline.match?(pattern) : cmdline.include?(pattern.to_s)
    end

    def process_alive?(pid)
      return false if pid.blank?

      ::Process.kill(0, Integer(pid))
      true
    rescue Errno::EPERM
      # 进程存在，只是当前用户无权向它发信号
      true
    rescue Errno::ESRCH, TypeError, ArgumentError
      false
    end

    def kill_process(pid)
      return if pid.blank?

      ::Process.kill("TERM", Integer(pid))
      sleep(0.3)
      ::Process.kill("KILL", Integer(pid)) if process_alive?(pid)
    rescue Errno::ESRCH, Errno::EPERM, TypeError, ArgumentError
      # 进程已退出
    end

    # 结束整个进程组：先 TERM 给优雅退出的机会（Chrome 退出时会 flush Cookie
    # 并写完 profile，SIGKILL 硬杀会截断落盘甚至损坏 profile），等
    # graceful_timeout 秒仍存活才 KILL。
    def kill_process_tree(pid, graceful_timeout: 8)
      return if pid.blank?

      ::Process.kill("TERM", -Integer(pid))
      deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + graceful_timeout
      while ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) < deadline
        return unless process_alive?(pid)

        sleep(0.2)
      end
      ::Process.kill("KILL", -Integer(pid))
    rescue Errno::ESRCH, Errno::EPERM, TypeError, ArgumentError
      kill_process(pid)
    end

    def chrome_binary
      ENV["BROWSER_PATH"].presence ||
        Ferrum::Browser::Binary.find(%w[chromium chromium-browser google-chrome google-chrome-stable]) ||
        raise(BrowserLogin::Error, "未找到 Chrome/Chromium 可执行文件，请设置 BROWSER_PATH")
    end

    def chrome_major_version
      require "open3"
      out, _status = Open3.capture2e(chrome_binary, "--version")
      out[/\d+(?:\.\d+)+/].to_s.split(".").first
    rescue StandardError
      nil
    end

    def alloc_port
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close
      port
    end

    # 返回 [pid, display_id]
    def spawn_xvfb
      display_id = (Time.now.to_f * 1000).to_i % 100_000_000
      path = Ferrum::Browser::Binary.find("Xvfb") or raise BrowserLogin::Error, "未找到 Xvfb，请先安装 xvfb（有界面模式依赖它）"
      pid = ::Process.spawn(path, ":#{display_id}", "-screen", "0",
                            "#{VIEWPORT[:width]}x#{VIEWPORT[:height]}x24",
                            in: File::NULL, out: File::NULL, err: File::NULL)
      ::Process.detach(pid)
      raise BrowserLogin::Error, "Xvfb 启动失败" unless process_alive?(pid)

      [ pid, display_id ]
    end
  end
end
