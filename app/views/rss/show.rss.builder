xml.instruct! :xml, version: "1.0"
xml.rss version: "2.0" do
  xml.channel do
    xml.title @account.nickname
    xml.description "RSS feed for #{@account.nickname}"
    xml.link account_rss_url(@account.fakeid)
    xml.language "zh-CN"

    if @account.round_head_img.present?
      xml.image do
        xml.url @account.round_head_img
        xml.title @account.nickname
        xml.link account_rss_url(@account.fakeid)
      end
    end

    @articles.each do |article|
      xml.item do
        xml.title article.title
        xml.link article.url
        xml.description article.best_digest
        xml.author article.author if article.author.present?
        xml.pubDate article.published_at.rfc822 if article.published_at
        xml.guid article.url, isPermaLink: "true"
      end
    end
  end
end
