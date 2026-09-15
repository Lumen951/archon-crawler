require "async"
require "async/semaphore"

# Crawls Rednote (Xiaohongshu) accounts. Orchestration across accounts
# (concurrency, pausing, retry scheduling) is handled by CrawlOrchestrator;
# this class only knows how to crawl a single Rednote account's notes.
class RednoteCrawler < BaseCrawler
  NOTE_URL_BASE = "https://www.xiaohongshu.com/explore"

  # ── Logging ────────────────────────────────────────────

  def self.log(crawl_task, level, message, context: nil)
    Rails.logger.send(level, "[RednoteCrawler] #{message}")
    crawl_task&.log(level, "[RednoteCrawler] #{message}", context: context)
  end

  # ── API 计费 ───────────────────────────────────────────

  # 记录一次被计费的 API 调用：累加到本次任务的小红书额度统计，并打一条 debug 日志。
  # 日志页只渲染 message，所以数字要写进 message；context 里再放一份结构化的，便于以后统计。
  def self.track_usage(crawl_task, account, label, usage)
    crawl_task.api_usage_tally.record(account.class.name, cost: usage.cost, balance: usage.balance)

    parts = []
    parts << "消耗 #{ApiUsageTally.format_credits(usage.cost)} 积分" if usage.cost
    parts << "余额 #{ApiUsageTally.format_credits(usage.balance)}" if usage.balance
    detail = parts.any? ? " — #{parts.join('，')}" : ""
    log(crawl_task, :debug, "#{account.nickname}: #{label} API 调用#{detail}",
        context: { kind: "api_usage", endpoint: label, cost: usage.cost, balance: usage.balance })
  end

  # CrawlOrchestrator 在小红书平台所有帐号抓完后调用一次，把摘要拼到"平台抓取完成"日志行上。
  # 无记录时返回 nil，由调用方保持原有的日志输出。
  def self.platform_crawl_summary(crawl_task)
    totals = crawl_task.api_usage_tally.totals_for(RednoteAccount.name)
    return nil if totals.nil? || totals[:calls].zero?

    parts = [ "共调用 API #{totals[:calls]} 次" ]
    parts << "消耗 #{ApiUsageTally.format_credits(totals[:cost])} 积分" if totals[:cost]
    parts << "余额 #{ApiUsageTally.format_credits(totals[:balance])}" if totals[:balance]
    parts.join("，")
  end

  # Note: Rednote's API is rate-sensitive, so notes within an account are
  # fetched sequentially rather than using article_concurrency (kept in the
  # signature only to conform to BaseCrawler).
  def self.crawl_account(account, crawl_task, article_concurrency:, max_pages:)
    task_account = crawl_task.crawl_task_accounts.find_by(account: account)
    task_account&.mark_running!

    log(crawl_task, :info, "开始抓取小红书帐号: #{account.nickname} (fakeid: #{account.fakeid})")
    page = 1
    new_count = 0
    skip_count = 0
    error_count = 0
    start_time = Time.current

    loop do
      break if crawl_task.reload.paused? || crawl_task.reload.failed?
      break if crawl_task.error_threshold_exceeded?(account.class.name)

      if max_pages > 0 && page > max_pages
        log(crawl_task, :debug, "#{account.nickname}: 已达到最大页数限制（#{max_pages} 页）")
        break
      end

      data = Retryable.with_retry(
        crawl_task: crawl_task,
        context: "#{account.nickname}: 笔记列表获取 (page: #{page})"
      ) do
        RednoteApiClient.get_user_notes(account.fakeid, page: page) do |usage|
          track_usage(crawl_task, account, "笔记列表第 #{page} 页", usage)
        end
      end

      if data.nil?
        log(crawl_task, :warn, "#{account.nickname}: API 返回 nil，可能请求失败")
        break
      end

      notes = data&.dig("notes") || []

      if notes.empty?
        log(crawl_task, :debug, "#{account.nickname}: 已到达末尾（第 #{page} 页无更多笔记），原始数据: #{data.inspect.truncate(500)}")
        break
      end

      total_pages = data["total_pages"].to_i
      log(crawl_task, :info, "#{account.nickname}: 第 #{page} 页获取了 #{notes.size} 篇笔记 (共 #{total_pages} 页)")

      notes.each_with_index do |note_info, index|
        break if crawl_task.error_threshold_exceeded?(account.class.name)
        note_id = note_info["noteId"] || note_info["id"]
        title = note_info["title"].presence || "(无标题)"
        log(crawl_task, :info, "#{account.nickname}: [#{index + 1}/#{notes.size}] 正在处理笔记 #{note_id}: #{title}")

        result = fetch_and_save_note(note_info, account, crawl_task)
        case result
        when :saved
          new_count += 1
        when :skipped
          skip_count += 1
        when :error
          error_count += 1
        end
      end

      break if total_pages > 0 && page >= total_pages

      page += 1
    end

    elapsed = (Time.current - start_time).round(1)
    account.refresh_activity_counters!
    account.mark_crawled!
    task_account&.mark_completed!
    log(crawl_task, :info, "#{account.nickname}: 小红书抓取完成，耗时 #{elapsed} 秒 — 新增 #{new_count} 篇，跳过 #{skip_count} 篇，失败 #{error_count} 篇")

    { new_count: new_count, skip_count: skip_count, error_count: error_count }
  rescue StandardError => e
    task_account&.mark_failed!(e.message)
    crawl_task.increment_error_count!(account.class.name)
    log(crawl_task, :error, "#{account.nickname}: 抓取出错 - #{e.class}: #{e.message}")
    log(crawl_task, :error, "#{account.nickname}: 异常 backtrace: #{e.backtrace&.first(5)&.join(' | ')}")

    if [ RednoteApiClient::ApiKeyMissingError, RednoteApiClient::ApiInsufficientBalanceError ].any? { |klass| e.is_a?(klass) }
      crawl_task.fail_platform!(account.class.name)
      log(crawl_task, :error, "#{account.nickname}: #{e.message}，已中断#{account.platform_name}平台剩余帐号抓取")
    end

    { new_count: new_count, skip_count: skip_count, error_count: error_count + 1 }
  end

  def self.fetch_and_save_note(note_info, account, crawl_task)
    note_id = note_info["noteId"] || note_info["id"]
    return :error if note_id.blank?

    note_url = "#{NOTE_URL_BASE}/#{note_id}"

    if Article.exists?(url: note_url)
      log(crawl_task, :debug, "跳过重复笔记: #{note_info['title']} (#{note_id})")
      return :skipped
    end

    # Fetch full detail
    log(crawl_task, :debug, "正在获取笔记详情: #{note_id}")
    detail_data = fetch_note_detail_with_retry(note_id, account, crawl_task)
    unless detail_data
      log(crawl_task, :warn, "笔记 #{note_id} 详情获取失败，跳过")
      return :error
    end

    note_card      = detail_data["note_card"] || {}
    interact_info  = note_card["interact_info"] || {}

    title = note_card["title"].presence || note_info["title"].presence || "(无标题)"
    desc  = note_card["desc"].to_s.strip

    # First image as cover
    images = note_card["image_list"] || []
    cover_url = images.first&.then { |img| img["url"] || img["url_default"] || img["url_pre"] }

    # Tags → digest suffix
    tags    = (note_card["tag_list"] || []).filter_map { |t| "##{t['name']}" if t["name"].present? }.join(" ")
    digest  = [ desc.truncate(200), tags.presence ].compact.join(" ")

    create_time  = note_card["time"] || note_info["time"]
    published_at = create_time.present? ? Time.at(create_time.to_s.length > 10 ? create_time.to_i / 1000 : create_time.to_i) : nil

    Article.create!(
      account:          account,
      crawl_task:       crawl_task,
      title:            title,
      url:              note_url,
      author:           note_card.dig("user", "nickname").presence || account.nickname,
      digest:           digest,
      cover_url:        cover_url,
      content_markdown: desc,
      content_html:     desc.present? ? "<p>#{ERB::Util.html_escape(desc)}</p>" : nil,
      published_at:     published_at,
      raw_data:         detail_data
    )

    crawl_task.increment_progress!
    log(crawl_task, :info, "已保存笔记: #{title} (#{note_id})")
    :saved
  rescue ActiveRecord::RecordInvalid
    log(crawl_task, :debug, "跳过重复笔记（数据库冲突）: #{note_url}")
    :skipped
  rescue StandardError => e
    crawl_task.increment_error_count!(account.class.name)
    log(crawl_task, :error, "保存笔记 #{note_id} 失败: #{e.message}")
    :error
  end

  def self.fetch_note_detail_with_retry(note_id, account, crawl_task)
    Retryable.with_retry(
      crawl_task: crawl_task,
      context: "笔记详情获取 (#{note_id})"
    ) do
      RednoteApiClient.get_note_detail(note_id) do |usage|
        track_usage(crawl_task, account, "笔记详情 #{note_id}", usage)
      end
    end
  end
end
