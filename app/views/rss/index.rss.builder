xml.instruct! :xml, version: "1.0"
xml.rss version: "2.0" do
  xml.channel do
    xml.title "所有帐号文章 - #{@period_label}"
    xml.description "所有帐号文章RSS订阅 - #{@period_label}"
    xml.link all_accounts_rss_url(period: params[:period])
    xml.language "zh-CN"

    @articles.each do |article|
      xml.item do
        xml.title "[#{article.account.nickname}] #{article.title}"
        xml.link article.url
        xml.description article.digest || article.content_markdown&.truncate(200) || ""
        xml.author article.author if article.author.present?
        xml.pubDate article.published_at.rfc822 if article.published_at
        xml.guid article.url, isPermaLink: "true"
        xml.category article.account.nickname
      end
    end
  end
end
