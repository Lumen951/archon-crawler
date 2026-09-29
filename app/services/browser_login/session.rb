require "ferrum"
require "net/http"
require "uri"

module BrowserLogin
  # 远程浏览器登录的会话管理器。
  #
  # 架构：Chromium 由 BrowserLogin::Launcher 以独立进程启动（pgroup 脱离请求
  # 生命周期），带持久化 user-data-dir 与调试端口；会话元数据（端口/pid）存
  # Rails.cache，同时在 profile 目录落一份 pid 文件。每个请求通过 Ferrum 以
  # CDP 附着到该进程执行截图/交互，因此：
  #   - Puma 多 worker / 应用重启都不影响进行中的登录（重新附着即可）；
  #   - Ferrum 不负责 spawn，没有它的 finalizer 误杀浏览器进程的问题；
  #   - Rails.cache 过期后可凭 pid 文件收养仍存活的浏览器，不会泄漏进程。
  #
  # profile 目录的占用关系由 BrowserLogin::ProfileLock（flock）守卫：会话
  # 存活期间持锁，与 WechatArticleBrowserFetcher 的正文抓取互斥。
  #
  # 有界面模式（Option.browser_login_headed）下先拉起 Xvfb 虚拟显示再启动
  # Chrome，用于对 headless 更敏感的页面；默认 headless，无需 Xvfb。
  class Session
    SESSION_TTL = 15.minutes
    SCREENSHOT_QUALITY = 80
    VIEWPORT = Launcher::VIEWPORT

    # 每平台同时最多一个登录会话（ACTIVE key），全站最多 PROVIDERS 个 Chrome
    ACTIVE_KEY_PREFIX = "browser_login:active:"
    RECORD_KEY_PREFIX = "browser_login:session:"
    PROFILE_FLAG_FILE = ".browser_login_session.json"

    # 进程内缓存的 CDP 附着连接与 profile 锁（每个 Puma worker 各自维护一份）
    @attached = {}
    @attach_mutex = Mutex.new
    @start_mutex = Mutex.new
    @profile_locks = {}
    # 各会话上一次写入的 Cookie 快照内容（跳过无变化的重复写盘）
    @last_snapshot = {}

    class NotFoundError < Error
    end

    class << self
      # 打开（或续用）一个平台的登录浏览器。profile 里已有登录态时，页面会
      # 直接停在登录后的状态，无需重新扫码。
      def start(provider_key)
        provider = BrowserLogin.find(provider_key)
        @start_mutex.synchronize do
          cleanup_stale

          record = find_active(provider.key) || spawn_browser(provider)
          touch(record)
          {
            session_id: record["session_id"],
            provider: provider.key,
            label: provider.label,
            resumed: record["resumed"].present?,
            logged_in: provider.session_valid?,
            viewport: VIEWPORT
          }
        end
      end

      # 截一帧 + 探测/保存登录态。这是前端唯一轮询的端点。
      def frame(session_id, force_save: false)
        record = fetch(session_id)
        provider = BrowserLogin.find(record["provider"])
        touch(record)

        image = nil
        url = nil
        logged_in = false
        saved = record["saved_at"].present?
        identity = record["identity"]
        save_error = nil
        risk = nil

        with_page(record) do |page|
          cookies = page.cookies.all.values
          snapshot_cookies!(record, provider, cookies)
          logged_in = provider.logged_in?(cookies)

          if (logged_in && !saved) || force_save
            begin
              identity = provider.save!(page: page, cookies: cookies).to_s
              record["saved_at"] = now_iso
              record["identity"] = identity
              saved = true
            rescue StandardError => e
              Rails.logger.error("[BrowserLogin] #{provider.key} save failed: #{e.class}: #{e.message}")
              save_error = e.message
            end
          end

          # 平台风控文案（如小红书 300012）每帧检测，渲染进状态栏
          risk = provider.risk_hint(page)

          # 不带 path 时 Ferrum 直接返回 base64，这里不能再编码一次
          image = page.screenshot(format: :jpeg, quality: SCREENSHOT_QUALITY)
          url = page.url.to_s
        end

        # save! 成功后 record 带上了 saved_at/identity，必须回写缓存，
        # 否则下一次轮询会重新读旧记录、重复执行保存
        touch(record) if record["saved_at"].present?

        {
          session_id: session_id,
          image: image,
          image_mime: "image/jpeg",
          url: url,
          logged_in: logged_in,
          saved: saved,
          identity: identity,
          save_error: save_error,
          message: frame_message(provider, logged_in, saved, save_error, identity, risk)
        }
      end

      # 把前端映射好的输入事件转发给浏览器
      def interact(session_id, action)
        record = fetch(session_id)
        touch(record)

        with_page(record) do |page|
          case action[:type]
          when "click"
            page.mouse.click(x: action[:x].to_f, y: action[:y].to_f, button: :left)
          when "mousedown"
            # 拖拽（滑块拼图验证）由前端按 pointerdown/move/up 逐个转发：
            # 事件时序反映真实手速，比服务端合成路径更容易通过行为风控
            page.mouse.move(x: action[:x].to_f, y: action[:y].to_f)
            page.mouse.down(button: :left)
          when "mousemove"
            page.mouse.move(x: action[:x].to_f, y: action[:y].to_f)
          when "mouseup"
            page.mouse.up(button: :left)
          when "scroll"
            page.command("Input.dispatchMouseEvent", type: "mouseWheel",
                                                      x: action[:x].to_f, y: action[:y].to_f,
                                                      deltaX: action[:dx].to_f, deltaY: action[:dy].to_f)
          when "text"
            # Input.insertText 等价于 IME 上屏，CJK 与 ASCII 都可靠
            page.command("Input.insertText", text: action[:text].to_s)
          when "key"
            dispatch_special_key(page, action[:key].to_s)
          when "navigate"
            page.command("Page.navigate", url: validated_url(action[:url].to_s))
          when "refresh"
            page.refresh
          else
            raise Error, "未知操作类型: #{action[:type]}"
          end
        end

        { ok: true }
      end

      # 地址栏导航只接受 http/https。远程浏览器是管理员工具，但不给
      # file:/javascript:/内网探测类 scheme 开口子。
      def validated_url(url)
        uri = URI.parse(url)
        raise Error, "仅支持 http/https 链接" unless uri.is_a?(URI::HTTP) && uri.host.present?

        url
      rescue URI::InvalidURIError, URI::InvalidComponentError
        raise Error, "无效的链接：#{url[0, 100]}"
      end

      # 结束会话并杀掉浏览器进程。保留 user-data-dir，下次登录可直接复用 Cookie。
      def stop(session_id)
        record = session_id.present? && Rails.cache.read(record_key(session_id))
        destroy(record) if record
        { stopped: true }
      end

      # 该平台当前是否有存活的登录浏览器（返回会话记录含 port，否则 nil）。
      # 供 WechatArticleBrowserFetcher 等复用：有会话时附着开新标签页，而不是
      # 与登录会话抢同一个 profile。
      def active_record(provider_key)
        session_id = Rails.cache.read("#{ACTIVE_KEY_PREFIX}#{provider_key}")
        return nil unless session_id

        record = Rails.cache.read(record_key(session_id))
        return nil unless record

        return nil unless Launcher.process_alive?(record["pid"]) && Launcher.cdp_ready?(record["port"])

        record
      end

      # Rails.cache 已过期/丢失，但浏览器进程仍存活（profile 目录的 pid 文件
      # 可查）时的兜底记录。只读，供 WechatArticleBrowserFetcher 附着后复用
      # 浏览器内存里的 Cookie，不影响会话状态；进程已死或无记录时返回 nil。
      def orphan_record(provider_key)
        flag = flag_path(provider_key)
        return nil unless flag.exist?

        data = JSON.parse(flag.read)
        return nil unless data.is_a?(Hash) && data["pid"] && data["port"]

        return nil unless Launcher.process_alive?(data["pid"]) && Launcher.cdp_ready?(data["port"])

        { "port" => data["port"], "pid" => data["pid"], "xvfb_pid" => data["xvfb_pid"], "orphan" => true }
      rescue JSON::ParserError, StandardError
        nil
      end

      private

      def frame_message(provider, logged_in, saved, save_error, identity, risk = nil)
        if save_error
          "检测到登录态，但保存失败：#{save_error}"
        elsif saved && logged_in
          "已保存登录态#{identity.present? ? "（#{identity}）" : ""}，可结束会话"
        elsif risk
          risk
        elsif logged_in
          "已检测到登录态，正在保存..."
        else
          "等待登录：请在下方页面完成 #{provider.label} 的登录"
        end
      end

      # ── 会话记录 ──────────────────────────────────────

      def fetch(session_id)
        record = session_id.present? && Rails.cache.read(record_key(session_id))
        raise NotFoundError, "登录会话不存在或已过期" unless record

        record
      end

      def find_active(provider_key)
        record = active_record(provider_key)
        return nil unless record

        record["resumed"] = true
        record
      end

      # 拉起（或收养）浏览器并持有 profile 锁直到会话销毁
      def spawn_browser(provider)
        lock = ProfileLock.acquire(BrowserLogin.profile_dir_for(provider.key), timeout: 5)
        @profile_locks[provider.key] = lock
        begin
          adopt_orphan(provider.key) || launch_and_record(provider)
        rescue StandardError
          release_profile_lock(provider.key)
          raise
        end
      end

      def release_profile_lock(provider_key)
        lock = @profile_locks.delete(provider_key)
        lock&.release
      end

      def touch(record)
        record["last_activity_at"] = now_iso
        Rails.cache.write(record_key(record["session_id"]), record, expires_in: SESSION_TTL)
        Rails.cache.write("#{ACTIVE_KEY_PREFIX}#{record['provider']}", record["session_id"], expires_in: SESSION_TTL)
      end

      def destroy(record)
        # 会话记录跨容器重启存留，同一 pid 数字在新容器里可能属于任意进程，
        # 杀前按命令行核对（Chrome 带 --user-data-dir=profile，Xvfb 是
        # Xvfb 二进制），不匹配说明是复用的旧 pid，跳过以免误杀
        if Launcher.process_matches?(record["pid"], profile_dir_for(record["provider"]))
          kill_process_tree(record["pid"])
        else
          Rails.logger.info("[BrowserLogin] pid #{record['pid']} (#{record['provider']}) 不再是登录浏览器，跳过杀进程")
        end
        if record["xvfb_pid"].present? && Launcher.process_matches?(record["xvfb_pid"], "Xvfb")
          kill_process(record["xvfb_pid"])
        end
        @attached.delete(record["session_id"])
        release_profile_lock(record["provider"])
        Rails.cache.delete(record_key(record["session_id"]))
        Rails.cache.delete("#{ACTIVE_KEY_PREFIX}#{record['provider']}")
        flag = flag_path(record["provider"])
        flag.delete if flag.exist?
      rescue StandardError => e
        Rails.logger.warn("[BrowserLogin] destroy session error: #{e.message}")
      end

      # 容器/应用重启会丢 Rails.cache，但 Chrome 进程与 pid 文件还在。
      # 启动前按 pid 文件收养仍存活的浏览器，避免每次打开都泄漏一个 Chrome。
      def adopt_orphan(provider_key)
        flag = flag_path(provider_key)
        return nil unless flag.exist?

        data = JSON.parse(flag.read)
        return nil unless data.is_a?(Hash) && data["pid"] && data["port"]

        unless Launcher.process_alive?(data["pid"]) && Launcher.cdp_ready?(data["port"])
          flag.delete
          return nil
        end

        spawn_browser_record(provider_key, data["port"], data["pid"], data["xvfb_pid"]).tap do |record|
          record["resumed"] = true
        end
      rescue JSON::ParserError, StandardError => e
        Rails.logger.warn("[BrowserLogin] adopt orphan error (#{provider_key}): #{e.message}")
        nil
      end

      def cleanup_stale
        BrowserLogin::PROVIDERS.each_key do |provider_key|
          session_id = Rails.cache.read("#{ACTIVE_KEY_PREFIX}#{provider_key}")
          next unless session_id

          record = Rails.cache.read(record_key(session_id))
          if record.nil?
            Rails.cache.delete("#{ACTIVE_KEY_PREFIX}#{provider_key}")
          elsif stale?(record)
            destroy(record)
          end
        end
      end

      def stale?(record)
        Time.parse(record["last_activity_at"]) < SESSION_TTL.ago
      rescue StandardError
        true
      end

      def record_key(session_id)
        "#{RECORD_KEY_PREFIX}#{session_id}"
      end

      def now_iso
        Time.current.iso8601
      end

      # ── 浏览器进程 ────────────────────────────────────

      def launch_and_record(provider)
        headed = Option.browser_login_headed? && !Gem.win_platform?
        profile_dir = BrowserLogin.profile_dir_for(provider.key)
        FileUtils.mkdir_p(profile_dir)

        port, pid, xvfb_pid = Launcher.launch(profile_dir: profile_dir, url: provider.login_url, headed: headed)
        record = spawn_browser_record(provider.key, port, pid, xvfb_pid)
        record["headed"] = headed
        persist_flag(record)
        record
      end

      def spawn_browser_record(provider_key, port, pid, xvfb_pid)
        {
          "session_id" => SecureRandom.hex(16),
          "provider" => provider_key,
          "port" => port,
          "pid" => pid,
          "xvfb_pid" => xvfb_pid,
          "created_at" => now_iso,
          "last_activity_at" => now_iso
        }
      end

      # ── CDP 附着 ──────────────────────────────────────

      # 附着到已运行的 Chrome 执行一段操作。命令在进程内串行执行，避免
      # 多线程同时驱动同一页面；连接断开时自动重连一次。
      def with_page(record)
        attempt = 0
        begin
          browser = attach(record)
          @attach_mutex.synchronize do
            page = Launcher.first_page(browser)
            Launcher.pin_viewport(page)
            yield page
          end
        rescue Ferrum::Error, IOError, Errno::ECONNRESET, Errno::EPIPE => e
          @attached.delete(record["session_id"])
          attempt += 1
          retry if attempt < 2
          raise Error, "连接登录浏览器失败：#{e.class}: #{e.message}"
        end
      end

      def attach(record)
        @attached[record["session_id"]] ||= Launcher.attach(record["port"])
      end

      def dispatch_special_key(page, key)
        mapped = {
          "Enter" => :enter, "Backspace" => :backspace, "Escape" => :escape,
          "Tab" => :tab, "ArrowUp" => :up, "ArrowDown" => :down,
          "ArrowLeft" => :left, "ArrowRight" => :right,
          "Delete" => :delete, "Home" => :home, "End" => :end
        }[key]
        if mapped
          page.keyboard.type(mapped)
        elsif key.length == 1
          page.command("Input.insertText", text: key)
        end
      end

      # ── 进程工具（委托 Launcher）──────────────────────

      def process_alive?(pid)
        Launcher.process_alive?(pid)
      end

      def kill_process(pid)
        Launcher.kill_process(pid)
      end

      def kill_process_tree(pid)
        Launcher.kill_process_tree(pid)
      end

      def cdp_ready?(port)
        Launcher.cdp_ready?(port)
      end

      # ── Cookie 快照 ────────────────────────────────────

      # 每帧把目标域 Cookie 快照进 profile 目录（内容不变时跳过写盘）。
      # 会话级 Cookie（微信环境验证、slave_sid 等）Chrome 不会写进 profile，
      # 浏览器进程退出即丢；快照让 WechatArticleBrowserFetcher 在会话结束后
      # 拉起独立浏览器时仍能回灌这些状态，人工验证成果因此可留存。
      def snapshot_cookies!(record, provider, cookies)
        json = CookieExport.serialize(cookies, domain_pattern: provider.cookie_domain_pattern)
        return if @last_snapshot[record["session_id"]] == json

        CookieExport.save(profile_dir_for(record["provider"]), json)
        @last_snapshot[record["session_id"]] = json
      rescue StandardError => e
        Rails.logger.warn("[BrowserLogin] #{record['provider']} Cookie 快照写入失败: #{e.class}: #{e.message}")
      end

      # ── profile 目录与 pid 文件 ────────────────────────

      def profile_dir_for(provider_key)
        BrowserLogin.profile_dir_for(provider_key)
      end

      def flag_path(provider_key)
        Pathname.new(profile_dir_for(provider_key)) / PROFILE_FLAG_FILE
      end

      def persist_flag(record)
        flag_path(record["provider"]).write({
          "port" => record["port"],
          "pid" => record["pid"],
          "xvfb_pid" => record["xvfb_pid"],
          "updated_at" => now_iso
        }.to_json)
      end
    end
  end
end
