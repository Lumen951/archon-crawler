# 小红书浏览器采集通道：通过 RednoteBrowserFetcher 驱动真实 Chromium 读取账号
# 主页与笔记详情，落库复用 RednoteCrawler.save_note_with_detail（与付费 API
# 路径同一套 URL 方案、去重与字段映射）。由 RednoteCrawler.crawl_account 在
# Option.rednote_browser_crawl? 时分发进来，对 CrawlOrchestrator 仍是
# BaseCrawler 协议。
#
# 与 API 路径的差异：
#   - 列表分页变成主页滚动加载：max_pages 近似换算成滚动轮数上限
#     （API 一页 ≈ 30 篇，一轮滚动 ≈ 10~20 篇）；
#   - 浏览器操作全程串行（fetcher 内类级 Mutex + 页面导航限流器），
#     article_concurrency 不适用；
#   - 风控（300012 / IP 存在风险）与登录态失效是环境问题：终止本账号并把可
#     操作的修复指引写进任务日志，绝不把被拦截的页面当成「没有笔记的账号」，
#     也不 fail_platform——其他账号可能配置了不同代理仍可尝试。
class RednoteBrowserCrawler < BaseCrawler
  # max_pages（API 分页数）→ 滚动轮数的近似换算系数。
  SCROLLS_PER_PAGE = 2

  def self.log(crawl_task, level, message, context: nil)
    Rails.logger.send(level, "[RednoteBrowserCrawler] #{message}")
    crawl_task&.log(level, "[RednoteBrowserCrawler] #{message}", context: context)
  end

  def self.crawl_account(account, crawl_task, article_concurrency:, max_pages:)
    task_account = crawl_task.crawl_task_accounts.find_by(account: account)
    task_account&.mark_running!

    log(crawl_task, :info, "开始通过浏览器抓取小红书帐号: #{account.nickname} (fakeid: #{account.fakeid})")
    new_count = 0
    skip_count = 0
    error_count = 0
    start_time = Time.current

    RednoteBrowserFetcher.open_session(crawl_task: crawl_task) do |session|
      listing = session.fetch_profile_notes(account.fakeid, max_scrolls: scroll_cap(max_pages))
      notes = listing[:notes]
      suffix = listing[:truncated] ? "（达到滚动上限，可能未覆盖全部笔记）" : ""
      log(crawl_task, :info, "#{account.nickname}: 主页读取到 #{notes.size} 篇笔记#{suffix}")

      notes.each_with_index do |item, index|
        break if crawl_task.reload.paused? || crawl_task.reload.failed?
        break if crawl_task.error_threshold_exceeded?(account.class.name)

        title = item[:title].presence || "(无标题)"
        log(crawl_task, :info, "#{account.nickname}: [#{index + 1}/#{notes.size}] 正在处理笔记 #{item[:note_id]}: #{title}")

        result = process_note(item, account, crawl_task, session)
        case result
        when :saved
          new_count += 1
        when :skipped
          skip_count += 1
        when :error
          error_count += 1
        end
      end
    end

    elapsed = (Time.current - start_time).round(1)
    account.refresh_activity_counters!
    account.mark_crawled!
    task_account&.mark_completed!
    log(crawl_task, :info,
        "#{account.nickname}: 小红书浏览器抓取完成，耗时 #{elapsed} 秒 — 新增 #{new_count} 篇，跳过 #{skip_count} 篇，失败 #{error_count} 篇")

    { new_count: new_count, skip_count: skip_count, error_count: error_count }
  rescue RednoteBrowserFetcher::RiskControlError, RednoteBrowserFetcher::LoginRequiredError => e
    task_account&.mark_failed!(e.message)
    crawl_task.increment_error_count!(account.class.name)
    log(crawl_task, :error, "#{account.nickname}: 浏览器抓取被拦截，已终止本账号 - #{e.message}")
    { new_count: new_count, skip_count: skip_count, error_count: error_count + 1 }
  rescue StandardError => e
    task_account&.mark_failed!(e.message)
    crawl_task.increment_error_count!(account.class.name)
    log(crawl_task, :error, "#{account.nickname}: 浏览器抓取出错 - #{e.class}: #{e.message}")
    log(crawl_task, :error, "#{account.nickname}: 异常 backtrace: #{e.backtrace&.first(5)&.join(' | ')}")
    { new_count: new_count, skip_count: skip_count, error_count: error_count + 1 }
  end

  # 单篇处理：去重 → 浏览器读详情 → 共用落库入口。单篇失败只计数，不中断账号
  # 循环（与 API 路径一致的 error_threshold_exceeded? 兜底失控）。
  def self.process_note(item, account, crawl_task, session)
    note_id = item[:note_id]
    return :error if note_id.blank?

    note_url = RednoteCrawler.note_url_for(note_id)
    if Article.exists?(url: note_url)
      log(crawl_task, :debug, "跳过重复笔记: #{item[:title]} (#{note_id})")
      return :skipped
    end

    log(crawl_task, :debug, "正在获取笔记详情: #{note_id}")
    payload = session.fetch_note_detail(note_id, xsec_token: item[:xsec_token])
    unless payload
      log(crawl_task, :warn, "笔记 #{note_id} 详情读取失败，跳过")
      return :error
    end

    detail = RednoteBrowserFetcher.normalize_note_detail(payload)
    unless detail
      log(crawl_task, :warn, "笔记 #{note_id} 详情解析失败，跳过")
      return :error
    end

    RednoteCrawler.save_note_with_detail(
      { "noteId" => note_id, "title" => item[:title].to_s, "time" => nil },
      RednoteBrowserFetcher.detail_to_api_shape(detail, raw_payload: payload),
      account, crawl_task
    )
  rescue RednoteBrowserFetcher::NoteUnavailableError => e
    log(crawl_task, :warn, e.message)
    :error
  end

  # max_pages>0 时按近似系数换算滚动上限；未限制（-1）时用全局配置兜底防失控。
  def self.scroll_cap(max_pages)
    max_pages > 0 ? max_pages * SCROLLS_PER_PAGE : Option.rednote_browser_max_scrolls
  end
end
