module QrLogin
  # 后台 Job 用的轮询循环（设置页由前端 JS 自己轮询，MCP 工具自带短轮询，
  # 三者节奏不同，所以循环不放在策略类里）。
  module Polling
    POLL_INTERVAL = 5           # 两次轮询之间的间隔（秒）
    POLL_REQUEST_TIMEOUT = 10   # 单次请求超时（秒）——短轮询，避免长连接把 Job 卡死
    POLL_TIMEOUT = 5.minutes    # 整体最多等多久

    # 轮询到终态或超时。
    # → { status: :success, identity: } / { status: :expired | :error | :timeout, message: }
    def poll_until_done(provider, handle, log_context: nil)
      started_at = monotonic_time
      deadline = Time.current + POLL_TIMEOUT
      log_poll(log_context, :info, "polling started provider=#{provider.key} interval=#{POLL_INTERVAL}s request_timeout=#{POLL_REQUEST_TIMEOUT}s overall_timeout=#{POLL_TIMEOUT}s")

      attempt = 0
      loop do
        attempt += 1
        request_started_at = monotonic_time
        log_poll(log_context, :info, "poll attempt=#{attempt} begin elapsed_ms=#{elapsed_ms(started_at)}")

        result = provider.poll(handle, timeout: POLL_REQUEST_TIMEOUT, allow_retry: false)
        request_elapsed_ms = elapsed_ms(request_started_at)
        previous_handle = handle
        handle = result[:handle] if result[:handle].present?
        handle_updated = result[:handle].present? && result[:handle] != previous_handle
        log_poll(
          log_context,
          :info,
          "poll attempt=#{attempt} result status=#{result[:status].inspect} " \
          "request_elapsed_ms=#{request_elapsed_ms} handle_updated=#{handle_updated} " \
          "message=#{safe_message(result[:message])}"
        )

        case result[:status]
        when :success
          log_poll(log_context, :info, "poll terminal status=success attempts=#{attempt} elapsed_ms=#{elapsed_ms(started_at)}")
          log_poll(log_context, :info, "save_success begin")
          identity = provider.save_success!(result[:result])
          log_poll(log_context, :info, "save_success complete identity_present=#{identity.present?}")
          return { status: :success, identity: identity }
        when :expired, :error
          log_poll(log_context, :warn, "poll terminal status=#{result[:status]} attempts=#{attempt} elapsed_ms=#{elapsed_ms(started_at)}")
          return { status: result[:status], message: result[:message] }
        end

        if Time.current > deadline
          log_poll(log_context, :warn, "poll overall timeout attempts=#{attempt} elapsed_ms=#{elapsed_ms(started_at)}")
          break
        end

        log_poll(log_context, :debug, "poll attempt=#{attempt} waiting next_attempt_in=#{POLL_INTERVAL}s")
        sleep POLL_INTERVAL
      rescue StandardError => e
        log_poll(
          log_context,
          :error,
          "poll attempt=#{attempt} exception=#{e.class} message=#{safe_message(e.message)} " \
          "elapsed_ms=#{elapsed_ms(started_at)}"
        )
        raise
      end

      { status: :timeout }
    end

    private

    def log_poll(log_context, level, message)
      log_context&.call(level, message)
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((monotonic_time - started_at) * 1000).round
    end

    def safe_message(message)
      message.to_s.gsub(/[\r\n]+/, " ")[0, 200].inspect
    end
  end
end
