require "async"
require "async/semaphore"

# Crawls Twitter accounts. Orchestration across accounts
# (concurrency, pausing, retry scheduling) is handled by CrawlOrchestrator;
# this class only knows how to crawl a single Twitter account's tweets.
class TwitterCrawler < BaseCrawler
  TWEET_URL_BASE = "https://x.com/i/status"

  # ── Logging ────────────────────────────────────────────

  def self.log(crawl_task, level, message)
    Rails.logger.send(level, "[TwitterCrawler] #{message}")
    crawl_task&.log(level, "[TwitterCrawler] #{message}")
  end

  # Fetches tweets for a single Twitter account and saves them as articles.
  #
  # Note: Twitter's API is rate-sensitive, so tweets are fetched in a single
  # batch (the Python client handles pagination internally) rather than
  # page-by-page. article_concurrency is accepted in the signature to conform
  # to BaseCrawler but is not used for concurrent tweet saving.
  def self.crawl_account(account, crawl_task, article_concurrency:, max_pages:)
    task_account = crawl_task.crawl_task_accounts.find_by(account: account)
    task_account&.mark_running!

    log(crawl_task, :info, "开始抓取 Twitter 帐号: #{account.nickname} (fakeid: #{account.fakeid})")
    new_count = 0
    skip_count = 0
    error_count = 0
    start_time = Time.current

    begin
      # Fix legacy data: if fakeid contains a URL, resolve it to user_id.
      # The handle is usually embedded in the URL (e.g. https://x.com/foo), so
      # derive it from the URL as a fallback when twitter_screen_name is blank.
      user_id = account.fakeid.to_s
      if user_id.match?(%r{https?://|twitter\.com|x\.com}i)
        log(crawl_task, :warn, "#{account.nickname}: fakeid 包含 URL，尝试解析为 user_id...")
        screen_name = account.twitter_screen_name.presence ||
                      AccountResolver.normalize_twitter_screen_name(account.fakeid)
        if screen_name.present?
          users = TwitterApiClient.lookup_user(screen_name)
          if users.is_a?(Array) && users.first && users.first["rest_id"].present?
            user_id = users.first["rest_id"].to_s
            account.update_columns(fakeid: user_id, twitter_screen_name: screen_name)
            log(crawl_task, :info, "#{account.nickname}: 已更新 user_id: #{user_id}")
          else
            raise TwitterApiClient::ApiError, "无法通过 screen_name 查找 user_id（@#{screen_name} 可能已改名或停用）"
          end
        else
          raise TwitterApiClient::ApiError, "fakeid 格式错误且无法解析出 screen_name"
        end
      end

      log(crawl_task, :info, "#{account.nickname}: 正在获取推文列表... (user_id: #{user_id})")
      tweets = Retryable.with_retry(
        crawl_task: crawl_task,
        context: "#{account.nickname}: 推文列表获取"
      ) do
        TwitterApiClient.get_user_tweets(user_id)
      end

      if tweets.nil? || tweets.empty?
        log(crawl_task, :info, "#{account.nickname}: 未获取到推文")
      else
        log(crawl_task, :info, "#{account.nickname}: 获取到 #{tweets.size} 条推文")

        tweets.each_with_index do |tweet, index|
          break if crawl_task.reload.paused? || crawl_task.reload.failed?
          break if crawl_task.error_threshold_exceeded?(account.class.name)

          tweet_id = tweet["id_str"]
          text = tweet["full_text"].to_s.truncate(50)
          log(crawl_task, :info, "#{account.nickname}: [#{index + 1}/#{tweets.size}] 正在处理推文 #{tweet_id}: #{text}")

          result = fetch_and_save_tweet(tweet, account, crawl_task)
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
      log(crawl_task, :info, "#{account.nickname}: Twitter 抓取完成，耗时 #{elapsed} 秒 — 新增 #{new_count} 篇，跳过 #{skip_count} 篇，失败 #{error_count} 篇")
    rescue StandardError => e
      task_account&.mark_failed!(e.message)
      crawl_task.increment_error_count!(account.class.name)
      log(crawl_task, :error, "#{account.nickname}: 抓取出错 - #{e.class}: #{e.message}")
      log(crawl_task, :error, "#{account.nickname}: 异常 backtrace: #{e.backtrace&.first(5)&.join(' | ')}")

      if [ TwitterApiClient::ApiKeyMissingError ].any? { |klass| e.is_a?(klass) }
        crawl_task.fail_platform!(account.class.name)
        raise e
      end
    end

    { new_count: new_count, skip_count: skip_count, error_count: error_count }
  end

  def self.fetch_and_save_tweet(tweet, account, crawl_task)
    tweet_id = tweet["id_str"]
    return :error if tweet_id.blank?

    tweet_url = "#{TWEET_URL_BASE}/#{tweet_id}"

    if Article.exists?(url: tweet_url)
      log(crawl_task, :debug, "跳过重复推文: #{tweet_id}")
      return :skipped
    end

    text = tweet["full_text"].to_s
    screen_name = tweet["screen_name"].presence || account.nickname
    published_at = begin
      tweet["created_at"].present? ? Time.parse(tweet["created_at"]) : nil
    rescue
      nil
    end

    # Build HTML content from tweet text
    html_parts = []
    html_parts << "<p>#{ERB::Util.html_escape(text)}</p>" if text.present?
    if tweet["media_urls"]&.any?
      tweet["media_urls"].each do |url|
        html_parts << "<p><img src=\"#{ERB::Util.html_escape(url)}\" /></p>"
      end
    end
    content_html = html_parts.join("\n") if html_parts.any?

    # Use first media image as cover
    cover_url = tweet["media_urls"]&.first

    # Build digest with hashtags and engagement stats
    digest_parts = []
    digest_parts << text.truncate(200)
    if tweet["hashtags"]&.any?
      digest_parts << tweet["hashtags"].map { |h| "##{h}" }.join(" ")
    end
    stats = []
    stats << "❤#{tweet['favorite_count']}" if tweet["favorite_count"]&.> 0
    stats << "🔁#{tweet['retweet_count']}" if tweet["retweet_count"]&.> 0
    stats << "💬#{tweet['reply_count']}" if tweet["reply_count"]&.> 0
    stats << "👁#{tweet['view_count']}" if tweet["view_count"]&.> 0
    digest_parts << stats.join(" | ") if stats.any?
    digest = digest_parts.compact_blank.join(" — ")

    Article.create!(
      account:          account,
      crawl_task:       crawl_task,
      title:            text.truncate(80).presence || "(无文字推文)",
      url:              tweet_url,
      author:           screen_name,
      digest:           digest,
      cover_url:        cover_url,
      content_markdown: text,
      content_html:     content_html,
      published_at:     published_at,
      raw_data:         tweet
    )

    crawl_task.increment_progress!
    log(crawl_task, :info, "已保存推文: #{tweet_id} (#{screen_name})")
    :saved
  rescue ActiveRecord::RecordInvalid
    log(crawl_task, :debug, "跳过重复推文（数据库冲突）: #{tweet_url}")
    :skipped
  rescue StandardError => e
    crawl_task.increment_error_count!(account.class.name)
    log(crawl_task, :error, "保存推文 #{tweet_id} 失败: #{e.message}")
    :error
  end
end
