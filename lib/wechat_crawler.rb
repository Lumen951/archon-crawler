require 'async'
require 'async/semaphore'

# Crawls WeChat public accounts. Orchestration across accounts (concurrency,
# pausing, retry scheduling) is handled by CrawlOrchestrator; this class only
# knows how to crawl a single WeChat account's articles.
class WechatCrawler < BaseCrawler
  def self.crawl_account(account, crawl_task, article_concurrency:, max_pages:)
    task_account = crawl_task.crawl_task_accounts.find_by(account: account)
    task_account&.mark_running!

    crawl_task.log(:info, "开始抓取帐号：#{account.nickname}")
    article_semaphore = Async::Semaphore.new(article_concurrency)

    offset = 0
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
        break if crawl_task.error_threshold_exceeded?(account.class.name)

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
  rescue StandardError => e
    task_account&.mark_failed!(e.message)
    crawl_task.increment_error_count!(account.class.name)
    crawl_task.log(:error, "#{account.nickname}: 抓取出错 - #{e.message}")
    crawl_task.log(:error, "#{account.nickname}: 异常 backtrace: #{e.backtrace&.first(5)&.join(' | ')}")
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
      published_at: Time.at(article_data['create_time'].to_i),
      raw_data: article_data
    )

    crawl_task.increment_progress!
    crawl_task.log(:info, "已保存文章：#{article_data['title']}")
  rescue ActiveRecord::RecordInvalid => e
    crawl_task.log(:debug, "跳过重复文章：#{article_data['link']}")
  rescue StandardError => e
    crawl_task.increment_error_count!(account.class.name)
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
