xml.instruct! :xml, version: "1.0"
xml.rss version: "2.0" do
  xml.channel do
    xml.title "帐号列表 - 启用"
    xml.description "启用的帐号列表RSS订阅"
    xml.link active_accounts_list_rss_url
    xml.language "zh-CN"

    @accounts.each do |account|
      xml.item do
        xml.title account.nickname
        xml.link account_url(account)
        xml.description "#{account.article_count_summary}#{account.last_crawled_at ? " | 最后抓取: #{account.last_crawled_at.strftime('%Y-%m-%d %H:%M')}" : ''}"
        xml.pubDate (account.last_crawled_at || account.created_at).rfc822
        xml.guid account_url(account), isPermaLink: "true"
        xml.category "启用"
      end
    end
  end
end
