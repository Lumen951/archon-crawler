module Retryable
  # Application-level errors worth retrying with crawl task tracking.
  # Transport-level retries (timeout, connection failure, HTTP 5xx) are handled
  # by Faraday retry middleware on each API client's connection. This module
  # focuses on application-level errors (rate limits from response body) and
  # provides crawl task logging/error tracking that Faraday cannot.
  RETRYABLE_STATUS_CODES = (500..599).to_a + [0].freeze # 0 = no status (network error)

  # Execute a block with exponential backoff retry.
  #
  # For HTTP errors (exceptions responding to #status_code), only retries on
  # retryable status codes (5xx, 0). Client errors (4xx) are raised immediately.
  #
  # @param crawl_task [CrawlTask] for logging retry attempts
  # @param context [String] label for log messages (e.g. account nickname, note ID)
  # @param max_retries [Integer] maximum number of retries (default 3)
  # @param retry_on [Array<Class>] exception classes to retry on
  # @param retryable_codes [Array<Integer>] HTTP status codes to retry (default: 5xx + 0)
  # @yield the block to execute
  # @return [Object] block return value, or nil if all retries exhausted
  def self.with_retry(crawl_task:, context:, max_retries: 3, retry_on: [StandardError], retryable_codes: RETRYABLE_STATUS_CODES)
    retries = 0
    begin
      yield
    rescue *retry_on => e
      # API key errors are not retryable — no point retrying with an invalid/expired key.
      # Any platform's API client can mark its key error class with `include CrawlerApiKeyError`.
      if e.is_a?(CrawlerApiKeyError)
        crawl_task.log(:error, "#{context}: API 密钥错误，不重试：#{e.message}")
        raise e
      end
      
      if e.is_a?(WechatMpNativeApiClient::RateLimitError)
        crawl_task.log(:error, "#{context}: 触发速率限制，不重试：#{e.message}")
        raise e
      end

      # For HTTP errors, check status code before retrying
      if e.respond_to?(:status_code) && e.status_code.present?
        unless retryable_codes.include?(e.status_code)
          crawl_task.log(:error, "#{context}: HTTP #{e.status_code} 客户端错误，不重试：#{e.message}")
          raise e
        end
      end

      retries += 1
      if retries <= max_retries
        wait = 2**retries
        crawl_task.log(:warn, "#{context}: #{e.class} - #{e.message}，#{wait} 秒后重试（#{retries}/#{max_retries}）")
        sleep wait
        retry
      else
        crawl_task.log(:error, "#{context}: 超过重试次数（#{max_retries}），放弃：#{e.class} - #{e.message}")
        raise e
      end
    end
  end
end
