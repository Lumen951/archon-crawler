xml.instruct! :xml, version: "1.0"
xml.rss version: "2.0" do
  xml.channel do
    xml.title "#{@tag.name} - 标签订阅"
    xml.description "#{@tag.name} 标签下的帐号文章 RSS 订阅"
    xml.link tag_rss_url(@tag)
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
