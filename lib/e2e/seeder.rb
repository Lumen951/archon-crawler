require "base64"

module E2E
  # bin/e2e 每次运行前调用：把 E2E 专用数据库（E2E_DB_NAME，默认
  # mp_crawler_e2e）重置为确定性的初始状态。幂等，可重复执行。
  #
  # 只放「测试的输入」：账号、平台配置、mock 素材。文章一律不预置——
  # 它们是抓取链路的产物，由 Playwright 规范通过触发真实抓取产生。
  class Seeder
    # 公众号 fixture 数据，与 e2e/fixtures/wechat_mp/free_publish/3876543210.json 对应
    DEMO_FAKEID  = "3876543210"
    DEMO_NAME    = "E2E演示公众号"
    DEMO_AVATAR  = "/e2e-assets/avatar-e2e.svg"

    # 生产样本目录（gitignore；由 prod-sample skill 从服务器取回）
    SAMPLE_ROOT  = Rails.root.join("e2e/fixtures/samples").freeze

    ASSETS = %w[
      avatar-e2e.svg
      avatar-e2e-2.svg
      cover-1.svg
      cover-2.svg
      cover-3.svg
      figure-1.svg
      figure-2.svg
    ].freeze

    class << self
      def run!
        new.run
      end
    end

    # 与 lib/e2e_mock/handlers.rb 的 MOCK_TOKEN 保持一致
    MOCK_MP_TOKEN = "987654321"

    def run
      guard!
      seed_options
      seed_accounts
      seed_samples
      write_assets
      print_summary
    end

    private

    # 防止误把开发库清掉/污染
    def guard!
      unless Rails.env.development? && ENV["E2E_DB_NAME"].present?
        abort("e2e:seed 只能在 development 且设置了 E2E_DB_NAME 时运行（由 bin/e2e 负责）。" \
              "当前 E2E_DB_NAME=#{ENV['E2E_DB_NAME'].inspect}")
      end
    end

    def seed_options
      Option.set("wechat_api_provider", "weread_native")
      Option.set("max_crawl_pages", 1)
      # 活动调研（event research）的外部密钥全部是占位值：对应的
      # google.serper.dev / openai-proxy / open.api.tianyancha.com 都由
      # E2EMock 回放（见 lib/e2e_mock/handlers.rb）。
      Option.set("openai_api_key", "e2e-mock-llm-key")
      Option.set("serper_api_key", "e2e-mock-serper-key")
      Option.set("tianyancha_api_key", "e2e-mock-tianyancha-key")
      # 调研断点缓存在磁盘上（tmp/event_research），而 run id 会被
      # reset_db 的 TRUNCATE 重置复用——不清掉的话第二轮 e2e 会全程命中
      # 旧缓存，测不到真实管线。
      FileUtils.rm_rf(Rails.root.join("tmp", "event_research"))
      # 注入「已扫码」的 weread_native 会话，让抓取用例不依赖扫码用例；
      # 扫码用例自己会走 mock 的完整扫码链路并覆盖这里的值。
      Option.weread_native_session_started!(
        cookie_jar: { "wr_vid" => "100000", "wr_skey" => "e2eseededkey" },
        account_info: { "name" => "E2E演示号", "vid" => "100000" }
      )
      # mp_native 会话仅用于搜号 API（AccountResolver）；其余 provider 的 UI 已隐藏
      Option.wechat_mp_session_started!(
        cookie: "e2e_mock_session=1; slave_sid=e2eseededsession",
        token: MOCK_MP_TOKEN,
        account_info: { nickname: "E2E演示号" }
      )
    rescue StandardError => e
      abort("e2e:seed 写入 Option 失败：#{e.class}: #{e.message}")
    end

    def seed_accounts
      account = WechatAccount.find_or_initialize_by(fakeid: DEMO_FAKEID)
      account.nickname = DEMO_NAME
      account.round_head_img = DEMO_AVATAR
      account.total_articles = 3
      account.status = :active
      # weread_native 抓取用 book_id（MP_WXS_<数字>）；合成数字 fakeid 不在
      # base64 biz 形态里，需显式指定，否则 normalize_book_id 会失败
      account.metadata = (account.metadata || {}).merge("weread_mp_id" => "MP_WXS_#{DEMO_FAKEID}")
      account.save!
    end

    # 生产样本（prod-sample skill 经 Kamal 导出、scp 回 samples/ 目录）：
    # 存在即导入真实帐号与文章元数据/正文，让 E2E 跑在贴近真实的数据形态上。
    # samples/ 在 gitignore 里，绝不提交真实数据。
    def seed_samples
      accounts_file = SAMPLE_ROOT.join("accounts.json")
      return unless accounts_file.exist?

      rows = JSON.parse(accounts_file.read)
      rows.each do |row|
        next unless row["type"] == "WechatAccount" && row["fakeid"].present?

        account = WechatAccount.find_or_initialize_by(fakeid: row["fakeid"])
        account.nickname ||= row["nickname"].presence || "生产样本公众号"
        account.round_head_img ||= DEMO_AVATAR
        account.total_articles = row["total_articles"].to_i if row["total_articles"]
        account.status = :active
        book_id = weread_book_id_for(row["fakeid"])
        account.metadata = (account.metadata || {}).merge("weread_mp_id" => book_id) if book_id
        account.save!
      end

      articles_file = SAMPLE_ROOT.join("wechat_articles.json")
      return unless articles_file.exist?

      cover_cycle = ASSETS.grep(/\Acover-/).cycle
      JSON.parse(articles_file.read).each do |row|
        account = WechatAccount.find_by(fakeid: row["account_fakeid"])
        next unless account && row["url"].present?

        next if Article.exists?(url: row["url"])

        Article.create!(
          account: account,
          title: row["title"].presence || "（无标题样本）",
          url: row["url"],
          author: row["author"].presence,
          digest: row["digest"].presence,
          cover_url: cover_cycle.next,
          published_at: row["published_at"] ? Time.at(row["published_at"]) : nil,
          content_html: sample_content_html(row["content_key"])
        )
      rescue ActiveRecord::RecordInvalid, StandardError => e
        puts "[e2e:seed] 跳过样本文章 #{row['url'].inspect}：#{e.message}"
      end

      puts "[e2e:seed] 已导入生产样本：帐号 #{rows.size} 篇文章 #{Article.where.not(content_html: nil).count} 篇有正文"
    end

    # 样本帐号的微信读书 book_id：MP_WXS_ 形态原样用；base64 biz 形态解码出
    # 数字 id；已经是纯数字的直接拼（与 WereadNativeApiClient.normalize_book_id 一致）
    def weread_book_id_for(fakeid)
      id = fakeid.to_s
      return id if id.start_with?("MP_WXS_")

      digits = if id.match?(/\A\d+\z/)
                 id
               else
                 Base64.decode64(id).gsub(/[^0-9]/, "")
               end
      digits.presence && "MP_WXS_#{digits}"
    end

    # 样本正文存在 samples/wechat_mp/articles/<key>.html（整页形态），
    # 提取 #js_content 与真实抓取清洗后的形态一致
    def sample_content_html(key)
      return nil if key.blank?

      path = SAMPLE_ROOT.join("wechat_mp", "articles", "#{File.basename(key)}.html")
      return nil unless path.exist?

      doc = Nokogiri::HTML(path.read)
      doc.at_css("#js_content")&.inner_html.to_s.presence
    end

    # 文章封面/正文配图指向 /e2e-assets/*，这些 SVG 由种子任务生成到
    # public/e2e-assets/（gitignore）：不进仓库、不进生产镜像，截图里却有真实图片。
    def write_assets
      dir = Rails.root.join("public", "e2e-assets")
      FileUtils.mkdir_p(dir)
      ASSETS.each do |name|
        path = dir.join(name)
        next if path.exist?
        File.write(path, svg_for(name))
      end
    end

    def svg_for(name)
      palette = {
        "avatar" => ["#0ea5e9", "#6366f1"], "avatar-e2e-2" => ["#f59e0b", "#ef4444"],
        "cover-1" => ["#2563eb", "#22d3ee"], "cover-2" => ["#7c3aed", "#ec4899"],
        "cover-3" => ["#059669", "#84cc16"], "figure-1" => ["#0891b2", "#60a5fa"],
        "figure-2" => ["#9333ea", "#f472b6"]
      }
      from, to = palette.fetch(name, ["#475569", "#94a3b8"])
      label = name.delete_suffix(".svg").tr("-", " ")
      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="640" height="360" viewBox="0 0 640 360">
          <defs>
            <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0" stop-color="#{from}"/>
              <stop offset="1" stop-color="#{to}"/>
            </linearGradient>
          </defs>
          <rect width="640" height="360" rx="24" fill="url(#g)"/>
          <text x="320" y="188" font-family="sans-serif" font-size="34" font-weight="bold"
                fill="#ffffff" text-anchor="middle">#{label}</text>
          <text x="320" y="232" font-family="sans-serif" font-size="20" fill="#e2e8f0"
                text-anchor="middle">mp-crawler e2e fixture</text>
        </svg>
      SVG
    end

    def print_summary
      puts "[e2e:seed] 完成：WechatAccount=#{WechatAccount.count} Article=#{Article.count} " \
           "User=#{User.count} (库: #{ENV['E2E_DB_NAME']})"
    end
  end
end
