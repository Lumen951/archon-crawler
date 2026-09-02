namespace :rednote do
  desc "根据 crawl_logs 统计小红书第三方 API 调用量，用于预算估算"
  task api_usage: :environment do
    # 仅当 Option.verbose_mode? 开启时 CrawlLog 才会写入记录，因此这里统计的是
    # 抓取任务（crawl_task）产生的调用；account_resolver 等未绑定 crawl_task 的
    # 直接调用（如后台搜索、validate_key）不会出现在 crawl_logs 中。
    candidates = CrawlLog.where("message LIKE ?", "%篇笔记%")
                          .or(CrawlLog.where("message LIKE ?", "%正在获取笔记详情%"))
                          .or(CrawlLog.where("message LIKE ?", "%笔记列表获取%"))
                          .or(CrawlLog.where("message LIKE ?", "%笔记详情获取%"))
                          .or(CrawlLog.where("message LIKE ?", "%API 返回 nil%"))

    list_pattern       = /第\s*\d+\s*页获取了\s*\d+\s*篇笔记/    # get_user_notes 成功
    list_nil_pattern   = /API 返回 nil/                        # get_user_notes 调用但无数据
    list_retry_pattern = /^笔记列表获取 \(page: \d+\):/          # get_user_notes 重试
    detail_pattern     = /正在获取笔记详情:/                     # get_note_detail 首次调用
    detail_retry_pattern = /^笔记详情获取 \(.+\):/               # get_note_detail 重试

    calls = candidates.pluck(:logged_at, :message).filter_map do |logged_at, message|
      endpoint =
        case message
        when list_pattern, list_nil_pattern, list_retry_pattern then "/xhs/user_post3 (笔记列表)"
        when detail_pattern, detail_retry_pattern then "/xhs/note_detail4 (笔记详情)"
        end
      { at: logged_at, endpoint: endpoint } if endpoint
    end

    if calls.empty?
      puts "crawl_logs 中未找到小红书 API 调用记录（请确认 Option.verbose_mode? 已开启）"
      next
    end

    today = Date.today
    windows = {
      "今天"      => today..today,
      "昨天"      => (today - 1)..(today - 1),
      "过去 7 天"  => (today - 6)..today,
      "过去 30 天" => (today - 29)..today,
      "总计"      => Date.new(1970, 1, 1)..today
    }

    puts "小红书第三方 API 调用统计（基于 crawl_logs，可能低估未开启 verbose_mode 或非抓取任务触发的调用）"
    puts "=" * 70
    windows.each do |label, range|
      scoped = calls.select { |c| range.cover?(c[:at].to_date) }
      puts format("%-10s %5d 次", label, scoped.size)
    end

    puts
    puts "按接口统计（总计）"
    puts "-" * 70
    calls.group_by { |c| c[:endpoint] }.sort_by { |_, v| -v.size }.each do |endpoint, entries|
      puts format("%-30s %5d 次", endpoint, entries.size)
    end

    puts
    puts "按日统计（最近 7 天）"
    puts "-" * 70
    (0..6).map { |i| today - i }.reverse_each do |day|
      daily = calls.count { |c| c[:at].to_date == day }
      puts format("%-12s %5d 次", day.to_s, daily)
    end
  end
end
