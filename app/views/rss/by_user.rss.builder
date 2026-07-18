xml.instruct! :xml, version: "1.0"
xml.rss version: "2.0" do
  xml.channel do
    xml.title "个人订阅 - #{@period_label}"
    xml.description "基于你关注的标签过滤的文章 RSS 订阅"
    xml.link all_accounts_rss_url
    xml.language "zh-CN"

    @articles.each do |article|
      xml.item do
        xml.title "[#{article.account.nickname}] #{article.title}"
        xml.link article_url(article)
        xml.description article.best_digest
        xml.author article.author if article.author.present?
        xml.pubDate article.published_at.rfc822 if article.published_at
        xml.guid article.url, isPermaLink: "true"
        xml.category article.account.nickname
      end
    end
  end
end
