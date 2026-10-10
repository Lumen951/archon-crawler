require "rqrcode"

module E2eMock
  module Handlers
    # 通用兜底：按 fixture 目录约定找文件，找不到就返回 nil（Registry 会
    # 回 599 并在报错信息里说明缺哪个 fixture）。文件名规则：
    #   <prefix><path>.json  — 任意 JSON 端点
    #   <prefix><path>.html  — HTML 端点
    # path 里的 "/" 保留为目录层级，query 不参与文件名。
    module FixtureDir
      def handle(request)
        path = request.uri.path.chomp("/")
        path = "/index" if path.empty?
        %w[json html].each do |ext|
          name = File.join(fixture_prefix, "#{path}.#{ext}")
          next unless E2eMock.fixture_exist?(name)

          body = E2eMock.fixture(name)
          return { status: 200, body: body,
                   headers: { "Content-Type" => ext == "json" ? "application/json; charset=utf-8" : "text/html; charset=utf-8" } }
        end
        nil
      end

      def fixture_prefix
        raise NotImplementedError
      end
    end

    # ── mp.weixin.qq.com ─────────────────────────────────────────────
    #
    # 覆盖 WechatMpNativeApiClient 的全部外部端点：登录页 / 二维码图片 /
    # 扫码状态轮询 / bizlogin / 会话校验 / 文章列表 / 搜号 / 文章正文。
    # 扫码状态机：每点一次「获取登录二维码」重置计数，之后第 1 次轮询
    # waiting → 第 2 次 scanned → 第 3 次起 success（触发 complete_login 链）。
    module WechatMp
      MOCK_UUID   = "e2e0001uuid"
      MOCK_TOKEN  = "987654321"
      MOCK_COOKIE = "slave_sid=e2emocksession123"

      class << self
        def handle(request)
          path = request.uri.path
          query = request.uri.query_values || {}

          case path
          when "/"                        then login_page
          when "/cgi-bin/loginqrcode"     then qr_image
          when "/cgi-bin/scanloginqrcode" then scan_status
          when "/cgi-bin/bizlogin"        then biz_login(query)
          when "/cgi-bin/home"            then home_page
          when "/cgi-bin/searchbiz"       then fixture_json("wechat_mp/searchbiz.json")
          when "/cgi-bin/free_publish",
               "/cgi-bin/publish",
               "/cgi-bin/appmsgpublish",
               "/cgi-bin/appmsg"          then article_list(query)
          when "/s"                       then article_page("MOCKARTICLE1")
          when %r{\A/s/(?<slug>[^/]+)\z}  then article_page(Regexp.last_match[:slug])
          end
        end

        private

        def login_page
          @poll_count = 0
          { status: 200, body: E2eMock.fixture("wechat_mp/login_page.html"),
            headers: { "Content-Type" => "text/html; charset=utf-8" } }
        end

        def qr_image
          { status: 200, body: qr_png,
            headers: { "Content-Type" => "image/png" } }
        end

        # 真二维码图片（rqrcode 生成），保证 <img> 渲染与 image magic 校验都通过
        def qr_png
          @qr_png ||= RQRCode::QRCode.new("https://mp.weixin.qq.com/scan?e2e=1").as_png(size: 240).to_s
        end

        def scan_status
          @poll_count = (@poll_count || 0) + 1
          status_code = { 1 => 0, 2 => 4 }.fetch(@poll_count, 1)
          { status: 200,
            body: { status: status_code, message: "" }.to_json,
            headers: { "Content-Type" => "application/json; charset=utf-8",
                       "Set-Cookie" => MOCK_COOKIE } }
        end

        def biz_login(query)
          action = query["action"]
          body = if action == "startlogin"
                   { base_resp: { ret: 0, err_msg: "ok" } }
                 else
                   # complete_login 用 /token=([^&\s"']+)/ 从原始 body 提取 token
                   { base_resp: { ret: 0, err_msg: "ok" },
                     redirect_url: "/cgi-bin/home?t=home/index&lang=zh_CN&token=#{MOCK_TOKEN}" }
                 end
          { status: 200, body: body.to_json,
            headers: { "Content-Type" => "application/json; charset=utf-8",
                       "Set-Cookie" => MOCK_COOKIE } }
        end

        # validate_session 与 complete_login 的账号信息都会访问 home 页
        def home_page
          { status: 200, body: E2eMock.fixture("wechat_mp/home_page.html"),
            headers: { "Content-Type" => "text/html; charset=utf-8" } }
        end

        def article_list(query)
          fakeid = query["fakeid"].to_s
          offset = query["begin"].to_i
          name = "wechat_mp/free_publish/#{fakeid}.json"
          body = if E2eMock.fixture_exist?(name)
                   E2eMock.fixture(name)
                 else
                   # 该账号没有 fixture：返回空列表（客户端会以 ApiError 结束，
                   # 任务状态如实记录，与真实上游「无数据」行为一致）
                   { base_resp: { ret: 0, err_msg: "ok" }, free_publish_list: [] }.to_json
                 end
          { status: 200, body: body, headers: { "Content-Type" => "application/json; charset=utf-8" } }
        end

        # 文章正文页：按 slug 找 e2e/fixtures/wechat_mp/articles/<slug>.html
        #（或 samples 覆盖），找不到时回退到通用 fixture。
        def article_page(slug)
          name = "wechat_mp/articles/#{File.basename(slug.to_s)}.html"
          body = E2eMock.fixture_exist?(name) ? E2eMock.fixture(name) : E2eMock.fixture("wechat_mp/articles/MOCKARTICLE1.html")
          { status: 200, body: body, headers: { "Content-Type" => "text/html; charset=utf-8" } }
        end

        def fixture_json(name)
          { status: 200, body: E2eMock.fixture(name),
            headers: { "Content-Type" => "application/json; charset=utf-8" } }
        end
      end
    end

    # ── dajiala.com ──────────────────────────────────────────────────
    module Dajiala
      extend FixtureDir
      def self.fixture_prefix
        "dajiala"
      end
    end

    # ── api.tikhub.io ────────────────────────────────────────────────
    module TikHub
      extend FixtureDir
      def self.fixture_prefix
        "tikhub"
      end
    end

    # ── api.yddm.com（Rednote）────────────────────────────────────────
    module Rednote
      extend FixtureDir
      def self.fixture_prefix
        "rednote"
      end
    end

    # ── weread.qq.com（WeRead 直连，默认抓取 provider）────────────────
    #
    # 覆盖 WereadNativeApiClient 的全部外部端点：
    #   登录：POST /web/login/getuid → /web/login/getinfo（轮询）→
    #         /web/login/weblogin + /web/login/session/init
    #   抓取：GET /web/shelf/bookIds（订阅检查）→ GET /api/mp/cover（最新一篇）→
    #         GET /web/mp/content（正文页：window.cgiDataNew 元数据 + #js_content）
    # 扫码状态机与微信侧一致：每次 getuid 重置，之后第 1-2 次轮询 waiting、
    # 第 3 次起 success（触发 weblogin/session/init 换取会话 Cookie）。
    module WereadNative
      MOCK_UID     = "e2ewereaduid0001"
      MOCK_VID     = "100000"
      MOCK_NAME    = "E2E演示号"

      class << self
        def handle(request)
          path = request.uri.path
          query = request.uri.query_values || {}

          case [request.method.to_s.upcase, path]
          in "POST", "/web/login/getuid"        then getuid
          in "POST", "/web/login/getinfo"       then getinfo
          in "POST", "/web/login/weblogin"      then weblogin
          in "POST", "/web/login/session/init"  then session_init
          in "GET",  "/web/shelf/bookIds"       then shelf(query)
          in "POST", "/mp/shelf/addToShelf"     then json({ errCode: 0 })
          in "GET",  "/api/mp/cover"            then cover(query)
          in "GET",  "/web/mp/content"          then content_page(query)
          end
        end

        private

        def getuid
          @poll_count = 0
          json({ uid: MOCK_UID })
        end

        def getinfo
          @poll_count = (@poll_count || 0) + 1
          body = @poll_count >= 3 ? { vid: MOCK_VID, userInfo: { name: MOCK_NAME, vid: MOCK_VID } } : {}
          json(body)
        end

        def weblogin
          json({}, "Set-Cookie" => "wr_vid=#{MOCK_VID}; path=/; HttpOnly")
        end

        def session_init
          json({ cookies: { wr_skey: "e2eskey100" } },
               "Set-Cookie" => "wr_skey=e2eskey100; path=/; HttpOnly")
        end

        # 已在书架 → 跳过 addToShelf
        def shelf(query)
          book_id = Array(query["bookIds"]).first.to_s
          json({ bookIds: [book_id] })
        end

        def cover(query)
          book_id = query["bookId"].to_s
          name = "weread_native/cover/#{File.basename(book_id)}.json"
          body = if E2eMock.fixture_exist?(name)
                   fresh_cover(E2eMock.fixture(name))
                 else
                   # 没有 fixture 的帐号：无最新文章（与上游「未订阅/无内容」行为一致）
                   { errCode: 0, reviewId: "" }
                 end
          json_raw(body)
        end

        # 正文页：元数据来自 window.cgiDataNew（link 指向真实 mp.weixin 地址时，
        # 文章落库与后续正文下载都走 /s/<slug> 的 mp.weixin fixture）
        def content_page(query)
          review_id = query["reviewId"].to_s
          name = "weread_native/content/#{File.basename(review_id)}.html"
          body = E2eMock.fixture_exist?(name) ? E2eMock.fixture(name) : E2eMock.fixture("weread_native/content/e2ereview0001.html")
          { status: 200, body: fresh_create_time(body), headers: { "Content-Type" => "text/html; charset=utf-8" } }
        end

        # fixture 里的发布时间写死于录制当天，会随真实日期滑出 RSS「最近7天」
        # 这类时间窗口；回放时统一替换为当前时间，闭环不依赖墙钟日期。
        def fresh_cover(raw)
          cover = JSON.parse(raw)
          cover["time"] = Time.current.to_i if cover.is_a?(Hash)
          JSON.generate(cover)
        rescue JSON::ParserError
          raw
        end

        def fresh_create_time(html)
          html.gsub(/create_time:\s*'[^']*'/, "create_time: '#{Time.current.strftime('%Y-%m-%d %H:%M')}'")
        end

        def json(hash, extra_headers = {})
          json_raw(JSON.generate(hash), extra_headers)
        end

        def json_raw(body, extra_headers = {})
          { status: 200, body: body.to_s,
            headers: { "Content-Type" => "application/json; charset=utf-8" }.merge(extra_headers) }
        end
      end
    end

    # ── open.feishu.cn：推送接口一律成功 ──────────────────────────────
    module Feishu
      def self.handle(request)
        return { status: 200, body: { tenant_access_token: "e2e-mock-token" }.to_json,
                 headers: { "Content-Type" => "application/json; charset=utf-8" } } if request.uri.path.include?("tenant_access_token")

        { status: 200, body: { code: 0, msg: "ok (e2e mock)" }.to_json,
          headers: { "Content-Type" => "application/json; charset=utf-8" } }
      end
    end

    # ── google.serper.dev（活动调研的搜索）────────────────────────────
    #
    # 按查询内容分流：含人名的返回人物资料页结果，其余返回活动获奖名单
    # 结果。结果链接都指向 news.e2e-event.test（由 EventWeb 回放页面）。
    module Serper
      class << self
        def handle(request)
          payload = JSON.parse(request.body.to_s.presence || "{}")
          query = payload["q"].to_s
          fixture = query.include?("张三") ? "event_research/serper_person.json" : "event_research/serper_event.json"

          { status: 200, body: E2eMock.fixture(fixture),
            headers: { "Content-Type" => "application/json; charset=utf-8" } }
        rescue JSON::ParserError
          { status: 400, body: { error: "bad serper request" }.to_json,
            headers: { "Content-Type" => "application/json; charset=utf-8" } }
        end
      end
    end

    # ── open.api.tianyancha.com（活动调研的工商档案）──────────────────
    #
    # 所有 keyword 都返回同一家合成企业（E2E示例科技有限公司）：
    # 主要人员里有张三，供「人名 × 主要人员」交叉比对出任职记录。
    module Tianyancha
      def self.handle(_request)
        { status: 200, body: E2eMock.fixture("event_research/tianyancha_company.json"),
          headers: { "Content-Type" => "application/json; charset=utf-8" } }
      end
    end

    # ── OpenAI 兼容代理（活动调研的 LLM 抽取）────────────────────────
    #
    # 事件抽取与人物抽取共用同一份响应：fixture 的 output_text 内嵌一段
    # 抽取结果 JSON（人物抽取按 awards[0].people[0] 取人，两个阶段都兼容）。
    module LlmProxy
      @request_count = 0

      def self.handle(_request)
        @request_count += 1
        body = E2eMock.fixture("event_research/llm_response.json").force_encoding(Encoding::UTF_8)
        body = body.gsub("E2E示例科技有限公司", "E2E新增科技有限公司") if @request_count > 2
        { status: 200, body: body,
          headers: { "Content-Type" => "application/json; charset=utf-8" } }
      end
    end

    # ── news.e2e-event.test（调研抓取的目标页面）──────────────────────
    module EventWeb
      extend FixtureDir
      def self.fixture_prefix
        "event_research/pages"
      end
    end
  end
end
