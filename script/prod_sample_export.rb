# frozen_string_literal: true

# 生产样本数据导出（只读）。由 prod-sample skill 通过 Kamal 在生产容器执行：
#   bin/kamal app exec -i "bin/rails runner /rails/storage/e2e_sample_export.rb"
#
# 用途：为 E2E 回归测试提供"真实的 mock 数据"——真实帐号名、真实文章标题/
# 摘要/正文排版。输出写到 /rails/storage/e2e_sample/（持久卷），再由本地
# scp/tar 取回放进 e2e/fixtures/samples/（gitignore，绝不提交）。
#
# 红线：
#   * 只 SELECT，不写任何业务表；
#   * 字段白名单——绝不导出 Option（cookies/tokens/keys）、User、Session、
#     ApiKey、OAuth、BrowserLogin::Session、CrawlLog 等任何凭据或运维数据；
#   * 文章正文写盘时把外部图片域替换为本地占位符（测试不触网）。
#
# 可调参数（ENV）：
#   SAMPLE_OUTPUT_DIR          输出目录（默认 /rails/storage/e2e_sample）
#   SAMPLE_MAX_ACCOUNTS        最多导出多少个公众号（默认 3）
#   SAMPLE_MAX_ARTICLES        每号最多导出多少篇文章元数据（默认 5）
#   SAMPLE_MAX_CONTENT         最多导出多少篇正文 HTML（默认 4）
#
# 产出结构（与 e2e/fixtures 的约定同名，放 samples/ 即自动生效）：
#   e2e_sample/
#     manifest.json                          导出元信息
#     accounts.json                          帐号样本（种子用）
#     wechat_articles.json                   文章元数据样本（种子用）
#     weread_native/cover/<book_id>.json     weread_native 最新文章接口（mock 回放用）
#     weread_native/content/<review_id>.html weread_native 正文页（cgiDataNew 元数据 + 正文）
#     wechat_mp/articles/<slug>.html         mp.weixin 形态文章页（种子提取正文用）

OUTPUT_DIR      = ENV.fetch("SAMPLE_OUTPUT_DIR", "/rails/storage/e2e_sample")
MAX_ACCOUNTS    = ENV.fetch("SAMPLE_MAX_ACCOUNTS", "3").to_i
MAX_ARTICLES    = ENV.fetch("SAMPLE_MAX_ARTICLES", "5").to_i
MAX_CONTENT     = ENV.fetch("SAMPLE_MAX_CONTENT", "4").to_i

# 帐号数字 id → base64（mp 文章页 __biz 的形态），用于拼 free_publish fixture
def biz_for(fakeid)
  Base64.strict_encode64(fakeid.to_s)
end

# 公众号 fakeid → 微信读书 book_id（与 WereadNativeApiClient.normalize_book_id 一致）
def weread_book_id_for(fakeid)
  id = fakeid.to_s
  return id if id.start_with?("MP_WXS_")

  digits = id.match?(/\A\d+\z/) ? id : Base64.decode64(id).gsub(/[^0-9]/, "")
  digits.empty? ? "MP_WXS_0" : "MP_WXS_#{digits}"
end

# 文章 URL → /s/<slug> 的 slug（有 slug 用 slug；查询串形态的链接退化为按序号命名）
def slug_for(url, idx)
  path = URI.parse(url.to_s).path.to_s
  slug = path[/\A\/s\/([^\/]+)\z/, 1]
  slug || "SAMPLEARTICLE#{idx}"
rescue URI::InvalidURIError
  "SAMPLEARTICLE#{idx}"
end

# 正文里的外部图片（mmbiz/qpic 等）换成本地占位 SVG，保证 E2E 离线且截图不破图
def localize_images(html, label)
  placeholder = format(
    '<img src="data:image/svg+xml;base64,%s" alt="%s">',
    Base64.strict_encode64(placeholder_svg(label)),
    label
  )
  html.to_s.gsub(/<img[^>]*>/) { |img_tag|
    if img_tag.include?("data:image/svg+xml") || img_tag.include?("/e2e-assets/")
      img_tag
    else
      placeholder
    end
  }
end

def placeholder_svg(label)
  <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" width="640" height="360" viewBox="0 0 640 360">
      <rect width="640" height="360" rx="24" fill="#64748b"/>
      <text x="320" y="186" font-family="sans-serif" font-size="30" fill="#ffffff" text-anchor="middle">#{label}</text>
      <text x="320" y="224" font-family="sans-serif" font-size="18" fill="#e2e8f0" text-anchor="middle">生产样本配图（已本地化）</text>
    </svg>
  SVG
end

def article_page_html(title:, nickname:, biz:, create_time:, content_html:)
  <<~HTML
    <!DOCTYPE html>
    <html lang="zh_CN">
    <head>
      <meta charset="utf-8">
      <title>#{title}</title>
      <script>
        var biz = "#{biz}";
        var nickname = htmlDecode("#{nickname}");
        var msg_title = htmlDecode("#{title}");
        var create_time = "#{create_time}" * 1;
      </script>
    </head>
    <body id="activity-detail" class="zh_CN">
      <div id="js_article" class="rich_media">
        <h1 class="rich_media_title" id="activity-name">#{title}</h1>
        <div class="rich_media_content" id="js_content">#{content_html}</div>
      </div>
    </body>
    </html>
  HTML
end

# weread.qq.com/web/mp/content 形态的正文页：WereadNativeApiClient 的
# extract_cgi_data 从 window.cgiDataNew 取权威元数据（键名顶格），正文在 #js_content。
def weread_content_page_html(link:, create_time:, title:, digest:, nick_name:, content_html:)
  <<~HTML
    <!DOCTYPE html>
    <html lang="zh_CN">
    <head>
      <meta charset="utf-8">
      <title>#{title}</title>
      <script>
        window.cgiDataNew = {
            link: '#{link}',
            create_time: '#{create_time}',
            title: '#{title}',
            desc: '#{digest}',
            cdn_url: '',
            nick_name: '#{nick_name}',
            content_noencode: ''
        };
      </script>
    </head>
    <body>
      <div id="js_content">#{content_html}</div>
    </body>
    </html>
  HTML
end

require "fileutils"
require "json"
require "uri"

FileUtils.mkdir_p(OUTPUT_DIR)
FileUtils.mkdir_p(File.join(OUTPUT_DIR, "weread_native", "cover"))
FileUtils.mkdir_p(File.join(OUTPUT_DIR, "weread_native", "content"))
FileUtils.mkdir_p(File.join(OUTPUT_DIR, "wechat_mp", "articles"))

accounts = WechatAccount.order(articles_count: :desc).limit(MAX_ACCOUNTS)

account_rows = []
article_rows = []
content_count = 0

accounts.find_each do |account|
  account_rows << {
    "type" => "WechatAccount",
    "fakeid" => account.fakeid,
    "nickname" => account.nickname,
    "total_articles" => account.total_articles
  }

  # weread_native 回放：/api/mp/cover 只暴露「最新一篇」，book_id 与
  # WereadNativeApiClient.normalize_book_id 的规则一致
  articles = account.articles.order(published_at: :desc).limit(MAX_ARTICLES)
  latest = articles.first

  if latest
    book_id = weread_book_id_for(account.fakeid)
    review_id = slug_for(latest.url, 1)
    File.write(
      File.join(OUTPUT_DIR, "weread_native", "cover", "#{book_id}.json"),
      JSON.pretty_generate({
        "errCode" => 0,
        "reviewId" => review_id,
        "title" => latest.title,
        "digest" => latest.digest.to_s,
        "name" => account.nickname,
        "time" => latest.published_at&.to_i || latest.created_at.to_i
      })
    )
  end

  articles.find_each.with_index do |article, idx|
    slug = slug_for(article.url, idx + 1)
    epoch = article.published_at&.to_i || article.created_at.to_i

    article_rows << {
      "account_fakeid" => account.fakeid,
      "url" => article.url,
      "title" => article.title,
      "digest" => article.digest.to_s,
      "author" => article.author.to_s,
      "published_at" => epoch,
      "content_key" => slug
    }

    # 正文 HTML：限额内才落盘（含外链图片本地化）。两种形态共用一份正文：
    # weread_native/content/<reviewId>.html 供 mock 回放（cgiDataNew 元数据），
    # wechat_mp/articles/<slug>.html 供种子提取正文。
    next unless content_count < MAX_CONTENT && article.content_html.present?

    localized = localize_images(article.content_html, "fig-#{slug[0, 12]}")
    published = article.published_at&.in_time_zone("Asia/Shanghai")&.strftime("%Y-%m-%d %H:%M")

    File.binwrite(
      File.join(OUTPUT_DIR, "weread_native", "content", "#{slug}.html"),
      weread_content_page_html(
        link: article.url,
        create_time: published,
        title: article.title,
        digest: article.digest.to_s,
        nick_name: account.nickname,
        content_html: localized
      )
    )
    File.binwrite(
      File.join(OUTPUT_DIR, "wechat_mp", "articles", "#{slug}.html"),
      article_page_html(
        title: article.title,
        nickname: account.nickname,
        biz: biz_for(account.fakeid),
        create_time: epoch,
        content_html: localized
      )
    )
    content_count += 1
  end
end

File.write(File.join(OUTPUT_DIR, "accounts.json"), JSON.pretty_generate(account_rows))
File.write(File.join(OUTPUT_DIR, "wechat_articles.json"), JSON.pretty_generate(article_rows))
File.write(File.join(OUTPUT_DIR, "manifest.json"), JSON.pretty_generate(
  "exported_at" => Time.now.utc.iso8601,
  "rails_env" => Rails.env,
  "app_revision" => `git rev-parse --short HEAD 2>/dev/null`.strip,
  "account_count" => account_rows.size,
  "article_count" => article_rows.size,
  "content_count" => content_count,
  "limits" => { "accounts" => MAX_ACCOUNTS, "articles_per_account" => MAX_ARTICLES, "content" => MAX_CONTENT }
))

puts "[prod_sample_export] 完成：帐号 #{account_rows.size}，文章 #{article_rows.size}，正文 #{content_count} → #{OUTPUT_DIR}"
