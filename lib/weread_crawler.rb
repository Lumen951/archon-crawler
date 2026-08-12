require "async"
require "async/semaphore"

# WeRead (微信读书) 转发服务的公众号抓取器。
#
# 通过 WereadApiClient 获取文章列表（走 WeRead 转发），
# 再直接从 mp.weixin.qq.com 下载文章正文。
#
# 与 WechatCrawler 的关键区别:
#   - 使用 mpId (MP_WXS_xxx 格式) 而非 fakeid 标识公众号
#   - 分页从 page=1 开始递增，而非 offset 偏移
#   - 文章列表来自 WeRead 服务，正文从微信服务器直接拉取
#
class WereadCrawler < BaseCrawler
  PAGE_SIZE = 20

  def self.crawl_account(account, crawl_task, article_concurrency:, max_pages:)
    task_account = crawl_task.crawl_task_accounts.find_by(account: account)
    task_account&.mark_running!

    mp_id = account.weread_mp_id

    # Auto-resolve: if mp_id doesn't look like a WeRead mpId (MP_WXS_xxx),
    # try to resolve it using an existing article URL
    unless mp_id.to_s.match?(/\AMP_WXS_/)
      article = account.articles.order(published_at: :desc).first
      if article&.url.present?
        begin
          result = WereadApiClient.get_mp_info(article.url, crawl_task: crawl_task)
          if result.is_a?(Array) && result.any? && result.first["id"].present?
            new_mp_id = result.first["id"]
            account.metadata ||= {}
            account.metadata["weread_mp_id"] = new_mp_id
            account.save!
            mp_id = new_mp_id
            crawl_task.log(:info, "#{account.nickname}: 已通过文章URL解析到 WeRead mpId: #{new_mp_id}")
          end
        rescue => e
          crawl_task.log(:error, "#{account.nickname}: 解析 WeRead mpId 失败: #{e.message}")
          raise WereadApiClient::ApiError, "解析 WeRead mpId 失败：#{e.message}"
        end
      else
        crawl_task.log(:error, "#{account.nickname}: 无文章可用于解析 WeRead mpId，无法抓取")
        raise WereadApiClient::ApiError, "无法解析 WeRead mpId：帐号 #{account.nickname} 没有文章，无法通过文章URL获取 mpId"
      end
    end

    crawl_task.log(:info, "开始抓取帐号：#{account.nickname} (mpId: #{mp_id})")

    article_semaphore = Async::Semaphore.new(article_concurrency)
    page = 1
    pages_crawled = 0

    loop do
      break if crawl_task.reload.paused? || crawl_task.reload.failed?
      break if crawl_task.error_threshold_exceeded?(account.class.name)

      if max_pages > 0 && pages_crawled >= max_pages
        crawl_task.log(:info, "#{account.nickname}: 已达到最大页数限制（#{max_pages} 页）")
        break
      end

      response = Retryable.with_retry(
        crawl_task: crawl_task,
        context: "#{account.nickname}: 文章列表获取 (page: #{page})"
      ) do
        WereadApiClient.get_articles(
          mp_id,
          page: page,
          crawl_task: crawl_task
        )
      end
      break unless response

      articles_data = response["articles"] || []

      if articles_data.empty?
        crawl_task.log(:info, "#{account.nickname}: 已到达末尾 (page #{page})")
        break
      end

      crawl_task.log(:info, "#{account.nickname}: 获取了 #{articles_data.size} 篇文章（第 #{page} 页）")

      articles_data.each do |article_data|
        break if crawl_task.error_threshold_exceeded?(account.class.name)

        article_semaphore.async do
          fetch_and_save_article(article_data, account, crawl_task)
        end
      end

      # WeRead page-based pagination: 如果返回数量 < PAGE_SIZE 则到末尾
      if articles_data.size < PAGE_SIZE
        crawl_task.log(:info, "#{account.nickname}: 已到达末尾 (不足一页)")
        break
      end

      pages_crawled += 1
      page += 1

      delay = Option.weread_update_delay_time
      sleep delay if delay > 0
    end

    account.refresh_activity_counters!
    account.update_column(:last_crawled_at, Time.current)
    task_account&.mark_completed!
    crawl_task.log(:info, "#{account.nickname}: 抓取完成")
  rescue StandardError => e
    task_account&.mark_failed!(e.message)
    crawl_task.increment_error_count!(account.class.name)
    crawl_task.log(:error, "#{account.nickname}: 抓取出错 - #{e.message}")
    crawl_task.log(:error, "#{account.nickname}: 异常 backtrace: #{e.backtrace&.first(5)&.join(' | ')}")
    Rails.logger.error("Account #{account.fakeid} WeRead crawl error: #{e.message}")
  end

  def self.fetch_and_save_article(article_data, account, crawl_task)
    url = article_data["link"]
    return if url.blank?

    if Article.exists?(url: url)
      crawl_task.log(:debug, "跳过重复文章：#{article_data['title']}")
      return
    end

    crawl_task.log(:debug, "正在下载内容：#{article_data['title']}")

    html_content = download_with_retry(url, "html", crawl_task)
    markdown_content = Html2Text.convert(html_content)

    Article.create!(
      account: account,
      crawl_task: crawl_task,
      title: article_data["title"],
      url: url,
      author: article_data["author_name"].presence || "",
      digest: article_data["digest"].presence || "",
      cover_url: article_data["cover"],
      content_markdown: markdown_content,
      content_html: html_content,
      published_at: Time.at(article_data["create_time"].to_i),
      raw_data: article_data
    )

    crawl_task.increment_progress!
    crawl_task.log(:info, "已保存文章：#{article_data['title']}")
  rescue ActiveRecord::RecordInvalid => e
    crawl_task.log(:debug, "跳过重复文章：#{url}")
  rescue StandardError => e
    crawl_task.increment_error_count!(account.class.name)
    crawl_task.log(:error, "保存文章 #{url} 失败：#{e.message}")
  end

  def self.download_with_retry(url, format, crawl_task)
    Retryable.with_retry(
      crawl_task: crawl_task,
      context: "下载 #{url} (#{format})"
    ) do
      WechatCrawler.download_content(url, crawl_task: crawl_task)
    end
  end
end
