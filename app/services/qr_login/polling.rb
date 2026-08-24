module QrLogin
  # 后台 Job 用的轮询循环（设置页由前端 JS 自己轮询，MCP 工具自带短轮询，
  # 三者节奏不同，所以循环不放在策略类里）。
  module Polling
    POLL_INTERVAL = 5           # 两次轮询之间的间隔（秒）
    POLL_REQUEST_TIMEOUT = 10   # 单次请求超时（秒）——短轮询，避免长连接把 Job 卡死
    POLL_TIMEOUT = 5.minutes    # 整体最多等多久

    # 轮询到终态或超时。
    # → { status: :success, identity: } / { status: :expired | :error | :timeout, message: }
    def poll_until_done(provider, handle)
      deadline = Time.current + POLL_TIMEOUT

      loop do
        result = provider.poll(handle, timeout: POLL_REQUEST_TIMEOUT, allow_retry: false)
        handle = result[:handle] if result[:handle].present?

        case result[:status]
        when :success
          return { status: :success, identity: provider.save_success!(result[:result]) }
        when :expired, :error
          return { status: result[:status], message: result[:message] }
        end

        break if Time.current > deadline
        sleep POLL_INTERVAL
      end

      { status: :timeout }
    end
  end
end
