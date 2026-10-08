require "cgi"
require "uri"
require "ferrum"

# 小红书网页版的浏览器采集器：用真实 Chromium 打开账号主页与笔记详情页读取数据，
# 免去付费 API（RednoteApiClient）的按次计费。
#
# 与 WechatArticleBrowserFetcher 复用同一套浏览器基础设施（BrowserLogin::Launcher、
# ProfileLock、Cookie 快照），附着策略一致：
#   1. 优先附着到仍存活的「小红书（网页版）」登录浏览器（BrowserLogin::Session，
#      provider rednote_web，含 Rails.cache 过期但进程存活的孤儿），人工登录态直接
#      继承；
#   2. 否则拉起独立抓取浏览器（rednote_web_downloader profile），先回灌登录
#      profile 的 Cookie 快照（Session#frame 持续导出，含会话级 web_session），
#      快照缺失时再回退到 Option.rednote_web_cookie 里的历史 Cookie。
#
# 与微信「逐篇兜底」不同，这里是整段会话式抓取：一次 open_session 打开一个浏览
# 器，块内先滚动主页收集笔记列表（含跳转详情页必需的 xsec_token——2024 年起不带
# 有效 token 直接访问 /explore/{id} 会被拦截），再逐篇打开详情页读取正文。全程
# 类级 Mutex 串行，页面导航走独立限流器。
#
# 页面数据优先读 window.__INITIAL_STATE__（Vue 初始状态，字段形态随版本可能变化，
# 提取脚本做了多形态兼容），DOM 仅作兜底；风控 / 未登录 / 笔记不可见必须显式抛错，
# 绝不能把被拦截的页面当成「没有笔记的账号」。
class RednoteBrowserFetcher
  # go_to 返回后等待 JS 渲染的时间；滚动加载每轮的落定等待。
  LOAD_SETTLE_SECONDS = 2.0
  SCROLL_SETTLE_SECONDS = 1.2
  # 连续 N 轮滚动没有新笔记即认为加载到底（hasMore 信号缺失时的兜底停止条件）。
  IDLE_ROUNDS_BEFORE_STOP = 3
  # 详情页数据是异步接口写入的：每 0.5s 轮询一次，最长等 6s。
  DETAIL_POLL_INTERVAL = 0.5
  DETAIL_POLL_TIMEOUT = 6.0
  # 单账号笔记数硬上限，防止异常页面导致无限滚动。
  HARD_NOTE_CAP = 500

  # 登录浏览器的 provider（附着目标 + Cookie 快照来源），与 BrowserLogin::RednoteWeb#key 一致。
  PROFILE_PROVIDER = "rednote_web"
  # 独立抓取浏览器自己的 user-data-dir 命名空间（终身持锁不能占用登录目录）。
  DOWNLOADER_PROVIDER = "rednote_web_downloader"

  class Error < StandardError; end

  # 小红书风控（300012「IP 存在风险」等）。属环境问题：终止本账号，由用户修
  # 代理/网络或改用有界面模式后重试，而不是反复撞风控。
  class RiskControlError < Error; end

  # 页面拿不到任何账号数据（登录墙 / 登录态失效）。guidance 见错误消息。
  class LoginRequiredError < Error; end

  # 单篇笔记不可见（已删除 / 仅自己可见 / xsec_token 失效）。按单篇失败处理。
  class NoteUnavailableError < Error; end

  # 主页笔记提取：同时读取 __INITIAL_STATE__.user 与 DOM 卡片链接。状态数据提供
  # 标题/封面等稳定字段，DOM 链接补齐详情跳转必需的 xsec_token/xsec_source。
  PROFILE_EXTRACT_JS = <<~'JS'.freeze
    (() => {
      const result = { nickname: "", hasMore: null, notes: [] };
      const byId = new Map();
      const push = (id, xsec, title, cover, source) => {
        if (!id) return;
        const key = String(id);
        const candidate = {
          id: key,
          xsec_token: xsec ? String(xsec) : "",
          xsec_source: source ? String(source) : "",
          title: (title || "").trim(),
          cover: cover || ""
        };
        const existing = byId.get(key);
        if (existing) {
          if (!existing.xsec_token && candidate.xsec_token) existing.xsec_token = candidate.xsec_token;
          if (!existing.xsec_source && candidate.xsec_source) existing.xsec_source = candidate.xsec_source;
          if (!existing.title && candidate.title) existing.title = candidate.title;
          if (!existing.cover && candidate.cover) existing.cover = candidate.cover;
          return;
        }
        byId.set(key, candidate);
        result.notes.push(candidate);
      };
      const coverOf = (c) => {
        if (!c) return "";
        if (typeof c === "string") return c;
        const info = c.infoList || c.info_list || [];
        return c.url || c.urlDefault || c.url_default || c.urlPre || c.url_pre ||
          (info[0] && info[0].url) || "";
      };
      const collect = (list) => {
        (list || []).forEach((item) => {
          if (Array.isArray(item)) {
            collect(item);
            return;
          }
          if (!item || typeof item !== "object") return;
          const card = item.noteCard || item.note_card || item;
          const id = item.id || item.noteId || item.note_id || card.id || card.noteId || card.note_id;
          const xsec = item.xsecToken || item.xsec_token || card.xsecToken || card.xsec_token || "";
          const source = item.xsecSource || item.xsec_source || card.xsecSource || card.xsec_source || "";
          const title = card.displayTitle || card.display_title || card.title || "";
          push(id, xsec, title, coverOf(card.cover), source);
        });
      };
      const unwrap = (v) => (v && typeof v === "object" && v.value !== undefined ? v.value : v);
      try {
        const user = window.__INITIAL_STATE__ && window.__INITIAL_STATE__.user;
        if (user) {
          const pageData = unwrap(user.userPageData) || {};
          const profile = unwrap(pageData.user) || unwrap(user.user) || {};
          result.nickname = profile.nickname || profile.nickName || "";
          let bucket = unwrap(user.notes);
          if (bucket && typeof bucket === "object" && !Array.isArray(bucket)) {
            if (bucket.hasMore === false) result.hasMore = false;
            bucket = unwrap(bucket.notes) || [];
          }
          if (Array.isArray(bucket)) collect(bucket);
        }
      } catch (e) {}
      document.querySelectorAll('a[href*="/explore/"], a[href*="/search_result/"]').forEach((a) => {
        const href = a.getAttribute("href") || "";
        const m = href.match(/\/(?:explore|search_result)\/([0-9a-zA-Z]+)/);
        if (!m) return;
        let xsec = "";
        let source = "";
        try {
          const query = new URLSearchParams(href.split("?")[1] || "");
          xsec = query.get("xsec_token") || "";
          source = query.get("xsec_source") || "";
        } catch (e) {}
        const card = a.closest("section") || a.parentElement || a;
        const titleEl = card.querySelector(".title, a.title, .note-text");
        const img = card.querySelector("img");
        push(m[1], xsec, titleEl ? titleEl.innerText : "",
             img ? (img.src || img.getAttribute("data-src") || "") : "", source);
      });
      return result;
    })()
  JS

  # 笔记详情提取：优先 __INITIAL_STATE__.note.noteDetailMap（直接按 NOTE_ID 命中，
  # 失败时按「长得像笔记对象」扫描各 entry，兼容 .value 包装），DOM 兜底。NOTE_ID
  # 由调用方注入（JSON 字符串字面量）。
  DETAIL_EXTRACT_JS_TEMPLATE = <<~'JS'.freeze
    (() => {
      const NOTE_ID = %{note_id};
      const result = { note: null, blocked: false };
      const unwrap = (v) => (v && typeof v === "object" && v.value !== undefined ? v.value : v);
      const looksLikeNote = (o) => o && typeof o === "object" &&
        (o.title !== undefined || o.desc !== undefined) &&
        (Array.isArray(o.imageList) || Array.isArray(o.tagList) ||
         o.time !== undefined || o.video !== undefined);
      try {
        const map = window.__INITIAL_STATE__ && window.__INITIAL_STATE__.note &&
                    window.__INITIAL_STATE__.note.noteDetailMap;
        if (map) {
          const direct = map[NOTE_ID];
          const candidates = direct !== undefined ? [direct] : Object.keys(map).map((k) => map[k]);
          for (const raw of candidates) {
            const unwrapped = unwrap(raw);
            const note = unwrap(unwrapped && unwrapped.note);
            if (looksLikeNote(note)) { result.note = note; break; }
          }
        }
      } catch (e) {}
      const text = (sel) => { const el = document.querySelector(sel); return el ? el.innerText.trim() : ""; };
      result.dom = {
        title: text("#detail-title"),
        desc: text("#detail-desc"),
        author: text(".username"),
        date_text: text(".date"),
        tags: Array.from(document.querySelectorAll("#detail-desc a.tag"))
          .map((el) => el.innerText.replace(/^#/, "").trim()).filter(Boolean),
        images: Array.from(document.querySelectorAll(".media-container img, .swiper-slide img"))
          .map((img) => img.src || img.getAttribute("data-src") || "").filter(Boolean)
      };
      const bodyText = (document.body && document.body.innerText) || "";
      result.blocked = bodyText.indexOf("当前笔记暂时无法浏览") >= 0 ||
                       bodyText.indexOf("笔记不存在") >= 0;
      return result;
    })()
  JS

  @mutex = Mutex.new

  class << self
    # 打开一段浏览器会话执行块：优先附着存活的登录浏览器，否则拉起独立抓取浏览
    # 器（回灌 Cookie 快照）。块内通过 BrowserSession 串行复用同一浏览器；全程
    # 类级互斥——多账号并发抓取时逐个排队，降低触发风控的概率。
    def open_session(crawl_task: nil)
      @mutex.synchronize do
        session_record = BrowserLogin::Session.active_record(PROFILE_PROVIDER) ||
                         BrowserLogin::Session.orphan_record(PROFILE_PROVIDER)
        if session_record
          log(crawl_task, :info, "打开小红书浏览器会话：附着登录浏览器")
          attach_to_session(session_record, crawl_task) { |page| yield BrowserSession.new(page, crawl_task) }
        else
          log(crawl_task, :info, "打开小红书浏览器会话：拉起独立浏览器（Cookie 快照回灌）")
          launch_dedicated_session(crawl_task) { |page| yield BrowserSession.new(page, crawl_task) }
        end
      end
    end

    # 页面导航限流器（主页、详情页共用）。参数变化时重建，与 WechatCrawler.download_rate_limiter 同约定。
    def rate_limiter
      config = [ Option.rednote_browser_rate_limit, Option.rednote_browser_rate_window ]
      if @rate_limiter.nil? || @rate_limiter_config != config
        @rate_limiter_config = config
        @rate_limiter = RateLimiter.new(*config)
      end
      @rate_limiter
    end

    def reset_rate_limiter!
      @rate_limiter = nil
    end

    def log(crawl_task, level, message, context: nil)
      Rails.logger.send(level, "[RednoteBrowserFetcher] #{message}")
      crawl_task&.log(level, "[RednoteBrowserFetcher] #{message}", context: context)
    end

    # ── 归一化（纯函数，供测试） ──────────────────────────

    # 主页提取结果 → { nickname:, notes: [{note_id, xsec_token, xsec_source, title, cover_url}], has_more: }
    # 按 note_id 去重，后续记录只补齐前一条缺失的字段。
    def normalize_profile_payload(payload)
      return { nickname: "", notes: [], has_more: nil } unless payload.is_a?(Hash)

      by_id = {}
      Array(payload["notes"]).each do |raw|
        next unless raw.is_a?(Hash)

        note_id = raw["id"].to_s.strip
        next if note_id.blank?

        candidate = {
          note_id: note_id,
          xsec_token: raw["xsec_token"].to_s.strip,
          xsec_source: raw["xsec_source"].to_s.strip,
          title: raw["title"].to_s,
          cover_url: raw["cover"].to_s
        }
        existing = by_id[note_id]
        if existing
          merge_listing_item!(existing, candidate)
        else
          by_id[note_id] = candidate
        end
      end
      { nickname: payload["nickname"].to_s.strip, notes: by_id.values,
        has_more: payload["hasMore"] == false ? false : nil }
    end

    # 详情提取结果 → 归一化字段；页面里没有任何可用数据时返回 nil（由调用方按
    # 单篇失败处理）。time 统一成毫秒整数，缺失/非法保持 nil——绝不伪造 epoch。
    def normalize_note_detail(payload)
      return nil unless payload.is_a?(Hash)

      note = payload["note"].is_a?(Hash) ? payload["note"] : {}
      dom = payload["dom"].is_a?(Hash) ? payload["dom"] : {}

      title = note["title"].presence || dom["title"].presence
      desc  = note["desc"].to_s.strip
      desc  = dom["desc"].to_s.strip if desc.blank?
      images = images_from(note, dom)
      tags   = tags_from(note, dom)
      author = dig_string(note.dig("user", "nickname")) || dom["author"].to_s.strip
      time_ms = time_ms_from(note, dom)

      return nil if title.blank? && desc.blank? && images.empty?

      { title: title.presence, desc: desc, images: images, tags: tags,
        author: author, time_ms: time_ms }
    end

    # 归一化详情 → API 形状的 detail_data（RednoteCrawler.save_note_with_detail
    # 的输入契约）。raw_payload 是浏览器页面的原始提取结果，塞进 raw_data 保留
    # 「解析器产物 vs 上游原值」的来源痕迹。
    def detail_to_api_shape(detail, raw_payload: nil)
      shape = {
        "note_card" => {
          "title" => detail[:title],
          "desc" => detail[:desc],
          "image_list" => detail[:images].map { |url| { "url" => url } },
          "tag_list" => detail[:tags].map { |name| { "name" => name } },
          "time" => detail[:time_ms],
          "user" => { "nickname" => detail[:author] }.compact
        }.compact
      }
      shape["browser_raw"] = raw_payload if raw_payload
      shape
    end

    # 详情页导航 URL：带 xsec_source 与 xsec_token（列表页携带的跳转凭证）。
    def note_detail_url(note_id, xsec_token = nil, xsec_source: nil)
      source = xsec_source.to_s.strip.presence || "pc_user"
      url = "#{RednoteCrawler::NOTE_URL_BASE}/#{note_id}?xsec_source=#{CGI.escape(source)}"
      url += "&xsec_token=#{CGI.escape(xsec_token)}" if xsec_token.present?
      url
    end

    def merge_listing_item!(existing, candidate)
      %i[xsec_token xsec_source title cover_url].each do |field|
        existing[field] = candidate[field] if existing[field].to_s.strip.blank? && candidate[field].to_s.strip.present?
      end
      existing
    end

    private

    def attach_to_session(session_record, crawl_task)
      browser = BrowserLogin::Launcher.attach(session_record["port"])
      page = browser.create_page
      BrowserLogin::Launcher.pin_viewport(page)
      begin
        yield page
      ensure
        quietly { page.close }
        # 附着模式下 quit 只断开 CDP 连接，不会杀掉登录浏览器进程
        quietly { browser.quit }
      end
    rescue Ferrum::Error, IOError => e
      raise Error, "附着小红书登录浏览器失败：#{e.class}: #{e.message}"
    end

    # 独立抓取浏览器：一次会话拉起、用完即杀（rednote 是整段批量抓取，不是逐篇
    # 兜底，没有常驻复用的收益；用完即杀避免僵尸进程）。登录 profile 目录的
    # Cookie 快照（含会话级 web_session）回灌后才有登录态。
    def launch_dedicated_session(crawl_task)
      profile_dir = BrowserLogin.profile_dir_for(DOWNLOADER_PROVIDER)
      lock = BrowserLogin::ProfileLock.acquire(profile_dir, timeout: 5)
      raise Error, "小红书抓取浏览器环境（#{DOWNLOADER_PROVIDER} profile）正被其他进程占用" unless lock

      pid = nil
      xvfb_pid = nil
      browser = nil
      begin
        BrowserLogin::Launcher.clear_stale_chrome_locks(profile_dir)
        port, pid, xvfb_pid = BrowserLogin::Launcher.launch(
          profile_dir: profile_dir, url: "about:blank", headed: Option.browser_login_headed?
        )
        browser = BrowserLogin::Launcher.attach(port)
        page = browser.create_page
        BrowserLogin::Launcher.pin_viewport(page)
        restore_cookies!(page, crawl_task)
        yield page
      ensure
        quietly { browser&.quit }
        BrowserLogin::Launcher.kill_process_tree(pid) if pid
        BrowserLogin::Launcher.kill_process(xvfb_pid) if xvfb_pid
        lock.release
      end
    rescue Ferrum::Error, IOError, BrowserLogin::Error => e
      raise Error, "拉起小红书抓取浏览器失败：#{e.class}: #{e.message}"
    end

    # Cookie 来源优先级：登录浏览器 profile 的实时快照（Session#frame 持续导出，
    # 含会话级 Cookie）→ Option.rednote_web_cookie 的历史 Cookie（「保存登录态」
    # 落库的字符串）。单条失败不中断。
    def restore_cookies!(page, crawl_task)
      snapshot_dir = BrowserLogin.profile_dir_for(PROFILE_PROVIDER)
      entries = BrowserLogin::CookieExport.load(snapshot_dir)
      source = "Cookie 快照（#{entries.size} 条）"
      if entries.empty?
        entries = legacy_option_entries
        source = "Option 历史 Cookie（#{entries.size} 条）"
      end
      log(crawl_task, :info, "回灌小红书登录 Cookie：#{source}")
      return if entries.empty?

      restored = 0
      entries.each do |entry|
        page.cookies.set(entry)
        restored += 1
      rescue StandardError
        nil
      end
      log(crawl_task, :info, "Cookie 回灌结果：成功 #{restored}/#{entries.size} 条")
    end

    def legacy_option_entries
      Option.rednote_web_cookie.to_s.split(";").filter_map do |pair|
        name, _, value = pair.strip.partition("=")
        next if name.blank? || value.blank?

        { "name" => name, "value" => value, "domain" => ".xiaohongshu.com", "path" => "/" }
      end
    end

    def quietly
      yield
    rescue StandardError
      nil
    end

    # ── normalize_note_detail 的字段提取 ──────────────────

    def images_from(note, dom)
      list = Array(note["imageList"] || note["image_list"]).filter_map do |img|
        next unless img.is_a?(Hash)
        info = img["infoList"] || img["info_list"] || []
        img["url"] || img["urlDefault"] || img["url_default"] || img["urlPre"] || img["url_pre"] ||
          (info[0].is_a?(Hash) && info[0]["url"]) || ""
      end
      list = Array(dom["images"]) if list.reject(&:blank?).empty?
      list.map { |url| url.to_s }.reject(&:blank?).uniq
    end

    def tags_from(note, dom)
      names = Array(note["tagList"] || note["tag_list"]).filter_map do |tag|
        tag.is_a?(Hash) ? tag["name"].to_s.strip : nil
      end
      names = Array(dom["tags"]) if names.empty?
      names.map(&:to_s).reject(&:blank?).uniq
    end

    # 毫秒时间戳：秒级源值（< 10^12）换算成毫秒；非法/缺失保持 nil。
    def time_ms_from(note, dom)
      ms = coerce_ms(note["time"])
      return ms if ms

      parse_dom_date(dom["date_text"])
    end

    def coerce_ms(raw)
      ms =
        case raw
        when Integer then raw
        when Float then raw.to_i
        when String then raw.match?(/\A\d+\z/) ? raw.to_i : nil
        end
      return nil if ms.nil? || ms <= 0

      ms *= 1000 if ms < 1_000_000_000_000
      ms
    end
    # DOM 时间文案是小红书展示的北京时间（"2024-05-01 12:00" / "2024年5月1日"）。
    # 相对时间（"3天前"、"昨天"）无法还原为绝对时刻 → 保持 nil，不猜测。
    def parse_dom_date(text)
      return nil if text.blank?

      m = text.match(/(\d{4})[-年\/.](\d{1,2})[-月\/.](\d{1,2})日?(?:\s+(\d{1,2}):(\d{2}))?/)
      return nil unless m

      zone = Time.find_zone("Asia/Shanghai")
      t = zone.local(m[1].to_i, m[2].to_i, m[3].to_i, m[4].to_i, m[5].to_i) rescue nil
      t ? (t.to_i * 1000) : nil
    end

    def dig_string(value)
      value.to_s.strip.presence
    end
  end

  # ── 会话实例：一次 open_session 内串行复用的页面 ──────────

  class BrowserSession
    def initialize(page, crawl_task)
      @page = page
      @crawl_task = crawl_task
    end

    # 滚动读取主页笔记列表。
    # @return { nickname:, notes: [{note_id, xsec_token, title, cover_url}], truncated: }
    #   truncated=true 表示因达到滚动上限停止，列表可能不完整（hasMore 未确认到 false）。
    def fetch_profile_notes(user_id, max_scrolls: nil)
      max_scrolls = Option.rednote_browser_max_scrolls if max_scrolls.nil?
      navigate_to(profile_url(user_id))

      listing = extract_profile_listing!(initial: true)
      seen = {}
      nickname = listing[:nickname]
      listing[:notes].each do |item|
        existing = seen[item[:note_id]]
        existing ? RednoteBrowserFetcher.merge_listing_item!(existing, item) : seen[item[:note_id]] = item
      end

      rounds = 0
      idle_rounds = 0
      has_more = listing[:has_more]

      while has_more != false && rounds < max_scrolls && seen.size < RednoteBrowserFetcher::HARD_NOTE_CAP
        @page.evaluate("window.scrollTo(0, document.documentElement.scrollHeight)")
        sleep(RednoteBrowserFetcher::SCROLL_SETTLE_SECONDS)
        rounds += 1

        listing = extract_profile_listing!
        before = seen.size
        nickname = listing[:nickname] if listing[:nickname].present?
        listing[:notes].each do |item|
          existing = seen[item[:note_id]]
          existing ? RednoteBrowserFetcher.merge_listing_item!(existing, item) : seen[item[:note_id]] = item
        end
        has_more = false if listing[:has_more] == false

        if seen.size == before
          idle_rounds += 1
          break if idle_rounds >= RednoteBrowserFetcher::IDLE_ROUNDS_BEFORE_STOP
        else
          idle_rounds = 0
        end
      end

      RednoteBrowserFetcher.log(@crawl_task, :debug,
                                "主页滚动结束：#{seen.size} 篇笔记，滚动 #{rounds} 轮，hasMore=#{has_more.inspect}")
      { nickname: nickname.to_s, notes: seen.values, truncated: has_more != false }
    end

    # 打开单篇笔记详情页，返回页面原始提取 payload（note/dom/blocked 结构），由
    # 调用方 normalize_note_detail 归一。轮询超时仍无数据返回 nil；明确不可见
    # （已删除/仅自己可见）抛 NoteUnavailableError；风控抛 RiskControlError。
    def fetch_note_detail(note_id, xsec_token: nil, xsec_source: nil)
      if xsec_token.to_s.strip.blank?
        raise NoteUnavailableError,
              "笔记 #{note_id} 缺少详情页跳转凭证 xsec_token，未打开详情页；请检查主页列表提取或重新登录后重试"
      end

      RednoteBrowserFetcher.rate_limiter.wait
      target = RednoteBrowserFetcher.note_detail_url(note_id, xsec_token, xsec_source: xsec_source)
      RednoteBrowserFetcher.log(@crawl_task, :debug, "打开笔记详情页: #{target[0, 90]}")
      @page.go_to(target)

      deadline = RednoteBrowserFetcher::DETAIL_POLL_TIMEOUT.seconds.from_now
      loop do
        payload = @page.evaluate(detail_extract_js(note_id))
        verify_detail_page!(payload, note_id)
        return payload if RednoteBrowserFetcher.normalize_note_detail(payload)

        break if Time.current >= deadline
        sleep(RednoteBrowserFetcher::DETAIL_POLL_INTERVAL)
      end

      RednoteBrowserFetcher.log(@crawl_task, :warn, "笔记 #{note_id} 详情数据轮询超时")
      nil
    end

    private

    def profile_url(user_id)
      "https://www.xiaohongshu.com/user/profile/#{CGI.escape(user_id.to_s)}"
    end

    def detail_extract_js(note_id)
      format(RednoteBrowserFetcher::DETAIL_EXTRACT_JS_TEMPLATE, note_id: JSON.generate(note_id.to_s))
    end

    def navigate_to(url)
      RednoteBrowserFetcher.rate_limiter.wait
      @page.go_to(url)
      sleep(RednoteBrowserFetcher::LOAD_SETTLE_SECONDS)
    end

    # 提取主页数据，并做环境检查：风控文案 → RiskControlError；首屏既没有昵称
    # 也没有任何笔记 → LoginRequiredError（正常账号即使无笔记也能读到昵称，
    # 两者皆空说明页面被登录墙/风控挡住，绝不能当成空账号）。滚动中途的瞬时
    # 空结果不做此判定，交给空闲轮数兜底停止。
    def extract_profile_listing!(initial: false)
      verify_risk_control!
      payload = @page.evaluate(RednoteBrowserFetcher::PROFILE_EXTRACT_JS)
      listing = RednoteBrowserFetcher.normalize_profile_payload(payload)

      if initial && listing[:nickname].blank? && listing[:notes].empty?
        raise LoginRequiredError,
              "无法读取小红书主页数据（昵称与笔记列表均为空）：登录态可能已失效或被风控拦截。" \
              "请在设置页「远程浏览器登录」重新完成小红书网页版登录（或配置代理/开启有界面模式）后重试"
      end

      listing
    end

    def verify_detail_page!(payload, note_id)
      verify_risk_control!
      return unless payload.is_a?(Hash) && payload["blocked"]

      raise NoteUnavailableError,
            "笔记 #{note_id} 无法浏览（可能已删除、仅自己可见或跳转凭证已失效）"
    end

    def verify_risk_control!
      text = page_text
      return unless text.match?(BrowserLogin::RednoteWeb::RISK_TEXT)

      raise RiskControlError,
            "检测到小红书风控拦截（IP 存在风险，错误码 300012）：请在设置页「远程浏览器登录」中配置代理、" \
            "更换服务器/本机网络，或打开「有界面模式」后重试"
    end

    def page_text
      @page.evaluate("(document.body && document.body.innerText) || ''").to_s
    rescue StandardError
      ""
    end
  end
end
