module ApplicationHelper
  # 侧边栏高亮判断：精确匹配或路径前缀匹配（/accounts 同时命中 /accounts/123）
  def nav_active?(*paths)
    paths.any? { |p| request.path == p || request.path.start_with?("#{p}/") }
  end

  # Render the limited Markdown structure used by reports without accepting HTML.
  def daily_report_content(text)
    safe_join(text.to_s.split(/\n{2,}/).map do |block|
      if (heading = block.match(/\A(\#{1,3})\s+([^\n]+)\z/))
        content_tag("h#{heading[1].length}", heading[2])
      else
        content_tag(:p, block, class: "whitespace-pre-wrap")
      end
    end)
  end

  def event_search_queries(event, keywords: [])
    EventResearch::QueryBuilder.new(event: event, keywords: keywords)
  end
end
