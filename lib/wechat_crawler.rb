require 'async'
require 'async/semaphore'

class WechatCrawler
  def self.crawl(crawl_task)
    accounts = crawl_task.incomplete_accounts.where(type: "WechatAccount").to_a
    account_concurrency = crawl_task.effective_account_concurrency
    article_concurrency = crawl_task.effective_article_concurrency
    max_pages = Option.max_crawl_pages

    crawl_task.update!(status: :running, started_at: Time.current)
    crawl_task.clear_old_logs
    crawl_task.log(:info, "开始抓取任务，共 #{accounts.size} 个帐号")
    crawl_task.log(:info, "帐号并发：#{account_concurrency}，文章并发：#{article_concurrency}")
    crawl_task.log(:info, "最大页数：#{max_pages == -1 ? '无限制' : max_pages}")

    Async do |task|
      account_semaphore = Async::Semaphore.new(account_concurrency)

      accounts.each do |account|
        break if crawl_task.reload.paused? || crawl_task.reload.failed?
        break if crawl_task.error_threshold_exceeded?

        account_semaphore.async do
          crawl_account(account, crawl_task, article_concurrency, max_pages)
        end
      end
    end

    crawl_task.reload
    if crawl_task.running?
      if crawl_task.error_threshold_exceeded?
        crawl_task.mark_failed!("累计错误数（#{crawl_task.error_count}）超过阈值，任务终止")
      else
        crawl_task.mark_complete!
      end
    end
  rescue WechatApiClient::ApiKeyExpiredError => e
    crawl_task.log(:error, "API 密钥已过期：#{e.message}")
    crawl_task.update!(status: :paused, error_message: e.message)
  rescue StandardError => e
    crawl_task.mark_failed!(e.message)
    Rails.logger.error("CrawlTask##{crawl_task.id} 失败：#{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
  end

  private

  def self.crawl_account(account, crawl_task, article_concurrency, max_pages)
    task_account = crawl_task.crawl_task_accounts.find_by(account: account)
    task_account&.mark_running!

    crawl_task.log(:info, "开始抓取帐号：#{account.nickname}")
    article_semaphore = Async::Semaphore.new(article_concurrency)

    offset = 0
    pages_crawled = 0

    loop do
      break if crawl_task.reload.paused? || crawl_task.reload.failed?
      break if crawl_task.error_threshold_exceeded?

      unless Option.api_key_valid?
        crawl_task.log(:error, "API 密钥已过期 - 暂停抓取")
        crawl_task.update!(status: :paused, error_message: "API 密钥已过期")
        break
      end

      if max_pages > 0 && pages_crawled >= max_pages
        crawl_task.log(:info, "#{account.nickname}: 已达到最大页数限制（#{max_pages} 页）")
        break
      end

      response = Retryable.with_retry(
        crawl_task: crawl_task,
        context: "#{account.nickname}: 文章列表获取 (offset: #{offset})",
        retry_on: [WechatApiClient::ApiRateLimitError, StandardError]
      ) do
        WechatApiClient.get_articles(account.fakeid, begin_offset: offset, size: 20)
      end
      break unless response

      articles_data = response['articles'] || []

      if articles_data.empty?
        crawl_task.log(:info, "#{account.nickname}: 已到达末尾")
        break
      end

      crawl_task.log(:info, "#{account.nickname}: 获取了 #{articles_data.size} 篇文章（偏移 #{offset}）")

      articles_data.each do |article_data|
        break if crawl_task.error_threshold_exceeded?

        article_semaphore.async do
          fetch_and_save_article(article_data, account, crawl_task)
        end
      end

      offset += 20
      pages_crawled += 1

      sleep 0.5
    end

    account.update!(last_crawled_at: Time.current, total_articles: account.articles.count)
    task_account&.mark_completed!
    crawl_task.log(:info, "#{account.nickname}: 抓取完成")
  rescue WechatApiClient::ApiKeyExpiredError
    task_account&.mark_failed!("API 密钥已过期")
    raise
  rescue StandardError => e
    task_account&.mark_failed!(e.message)
    crawl_task.increment_error_count!
    crawl_task.log(:error, "#{account.nickname}: 抓取出错 - #{e.message}")
    Rails.logger.error("Account #{account.fakeid} crawl error: #{e.message}")
  end

  def self.fetch_and_save_article(article_data, account, crawl_task)
    return if article_data['link'].blank?

    if Article.exists?(url: article_data['link'])
      crawl_task.log(:debug, "跳过重复文章：#{article_data['title']}")
      return
    end

    crawl_task.log(:debug, "正在下载内容：#{article_data['title']}")

    markdown_content = download_with_retry(article_data['link'], 'markdown', crawl_task)
    html_content = download_with_retry(article_data['link'], 'html', crawl_task)

    Article.create!(
      account: account,
      crawl_task: crawl_task,
      title: article_data['title'],
      url: article_data['link'],
      author: article_data['author_name'],
      digest: article_data['digest'],
      cover_url: article_data['cover'],
      content_markdown: markdown_content,
      content_html: html_content,
      published_at: Time.at(article_data['create_time'].to_i)
    )

    crawl_task.increment_progress!
    crawl_task.log(:info, "已保存文章：#{article_data['title']}")
  rescue ActiveRecord::RecordInvalid => e
    crawl_task.log(:warn, "跳过重复文章：#{article_data['link']}")
  rescue StandardError => e
    crawl_task.increment_error_count!
    crawl_task.log(:error, "保存文章 #{article_data['link']} 失败：#{e.message}")
  end

  def self.download_with_retry(url, format, crawl_task, max_retries: 3)
    Retryable.with_retry(
      crawl_task: crawl_task,
      context: "下载 #{url} (#{format})",
      max_retries: max_retries
    ) do
      WechatApiClient.download_content(url, format: format)
    end
  end
end
