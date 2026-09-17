require "set"

namespace :weread_native do
  desc "回填微信读书（直连）抓取的文章：修正 1970 发布时间、替换为原始 mp.weixin 链接"
  task backfill: :environment do
    scope = Article.where("url LIKE ?", "%weread.qq.com/web/mp/content%")
    puts "待回填: #{scope.count} 篇"
    return if scope.count.zero?

    fixed = 0
    # 回填会把 url 改成 mp.weixin 链接，受影响帐号必须在循环中收集（事后按 url 反查会落空）
    account_ids = Set.new
    scope.find_each do |article|
      account_ids << article.account_id
      review_id = WereadNativeApiClient.extract_review_id(article.url)
      if review_id.blank?
        puts "跳过（无法解析 reviewId）: #{article.url}"
        next
      end

      begin
        # 一次抓取两用：cgiDataNew 元数据 + 缺失的正文
        html = WereadNativeApiClient.fetch_content_page(review_id)
      rescue StandardError => e
        puts "失败: #{article.title} - #{e.message}"
        next
      end
      cgi = WereadNativeApiClient.extract_cgi_data(html)
      if cgi.empty?
        puts "跳过（正文页无 cgiDataNew）: #{article.title}"
        next
      end

      # 目标 mp 链接已被其它文章占用（唯一索引），保留原 weread 链接，只修时间
      new_url = cgi["link"]
      url_taken = new_url.present? && Article.where(url: new_url).where.not(id: article.id).exists?

      attrs = {}
      attrs[:url] = new_url unless url_taken || new_url.blank?
      if cgi["create_time"].present? && (ts = WereadNativeApiClient.parse_wechat_time(cgi["create_time"]))
        attrs[:published_at] = Time.at(ts)
      end
      attrs[:digest] = cgi["digest"] if cgi["digest"].present? && article.digest.blank?
      attrs[:cover_url] = cgi["cover"] if cgi["cover"].present? && article.cover_url.blank?

      if article.content_html.blank?
        inner = WereadNativeApiClient.extract_element_html(html, "js_content")
        if inner.present?
          content_html = WereadNativeApiClient.clean_content(inner)
          attrs[:content_html] = content_html
          attrs[:content_markdown] = Html2Text.convert(content_html)
        end
      end

      if attrs.any?
        article.update!(**attrs,
          raw_data: (article.raw_data || {}).merge(cgi).merge("weread_link" => article.url))
        fixed += 1
        puts "已修正: #{article.title} (#{attrs.keys.join(', ')})"
      else
        puts "无变化: #{article.title}"
      end
    end

    # 刷新受影响帐号的活跃度计数与下次抓取时间：
    # published_at 修正后活跃度分层会变（1970 曾被判成 dead/never），
    # 只刷新计数而不重算 next_crawl_at，这些帐号仍会按 21/30 天的旧间隔调度。
    Account.where(id: account_ids.to_a).find_each do |account|
      account.refresh_activity_counters! # 更新 last_published_at / articles_count / activity_score
      account.reschedule_crawl!          # 按新的活跃度分层重算 next_crawl_at
      puts "帐号已刷新: #{account.nickname} last_published_at=#{account.last_published_at} next_crawl_at=#{account.next_crawl_at}"
    end
    puts "\n完成: 修正 #{fixed} 篇"
  end
end
