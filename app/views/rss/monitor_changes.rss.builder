xml.instruct! :xml, version: "1.0"
xml.rss version: "2.0" do
  xml.channel do
    xml.title @feed_title
    xml.description @feed_description
    xml.link @feed_link
    xml.language "zh-CN"
    xml.lastBuildDate @changes.first.created_at.rfc822 if @changes.first

    @changes.each do |change|
      account = change.account
      page = change.monitor_page
      change_items = Array(change.change_items).filter_map do |item|
        case item
        when Hash
          item.values.join("：")
        else
          item.to_s
        end.presence
      end
      content = (change_items.presence || [change.summary, page.current_version&.content].compact).join("\n")
      content = content.truncate(500)
      description = [
        content,
        "类型: #{change.change_type}",
        "新增: #{change.diff_added}，删除: #{change.diff_removed}"
      ].compact.join("\n")
      refer_url = change.refer_url.presence || page.url
      detail_url = monitor_change_url(change)

      xml.item do
        xml.title "[#{account.nickname}] #{page.display_title}"
        xml.link refer_url
        xml.description description
        xml.pubDate change.created_at.rfc822
        xml.guid detail_url, isPermaLink: "true"
        xml.category account.fakeid
        xml.category page.type_label if page.page_type.present?
        xml.category change.change_type if change.change_type.present?
      end
    end
  end
end
