xml.instruct! :xml, version: "1.0"
xml.rss version: "2.0" do
  xml.channel do
    xml.title @feed_title
    xml.description @feed_description
    xml.link @feed_link
    xml.language "zh-CN"
    if (latest = @pages.first)
      xml.lastBuildDate((latest.last_changed_at || latest.last_checked_at || latest.created_at).rfc822)
    end

    @pages.each do |page|
      account = page.account
      content = page.current_version&.content.to_s.truncate(500)
      description = [
        content,
        "类型: #{page.type_label}",
        "版本数: #{page.versions_count}"
      ].compact.join("\n")

      xml.item do
        xml.title "[#{account.nickname}] #{page.display_title}"
        xml.link page.url
        xml.description description
        xml.pubDate (page.last_changed_at || page.last_checked_at || page.created_at).rfc822
        xml.guid monitor_page_url(page), isPermaLink: "true"
        xml.category account.fakeid
        xml.category page.type_label if page.page_type.present?
      end
    end
  end
end
