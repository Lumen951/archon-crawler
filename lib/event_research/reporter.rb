# 运行日志的统一出口。级别分发、异常展开、脱敏在这里做，写到哪儿由 sink 决定：
#
#   * CLI（script/event_research.rb）：stdout 可读进度 + run.log 完整时间线
#   * 应用内（EventResearch::CrawlLogSink）：多态 CrawlLog（loggable = EventResearchRun）
#     + Rails.logger
#
# sink 的约定：响应 #call(level, message)（level 为 :debug/:info/:warn/:error 符号），
# 可选响应 #close。
class EventResearch::Reporter
  # backtrace 全量打印会把日志撑爆，取前 20 帧足够定位
  BACKTRACE_LIMIT = 20

  def initialize(sink)
    @sink = sink
  end

  def info(message)
    dispatch(:info, message)
  end

  def debug(message)
    dispatch(:debug, message)
  end

  def warn(message)
    dispatch(:warn, message)
  end

  # error 额外把异常与 backtrace 展开（debug 级别的细节按 error 落到 sink，
  # 只写日志，不刷屏 —— 刷屏策略由 sink 自己决定）。
  def error(message, exception: nil)
    dispatch(:error, message)

    return unless exception

    dispatch(:error, "  #{exception.class}: #{exception.message}")
    Array(exception.backtrace).first(BACKTRACE_LIMIT).each { |line| dispatch(:error, "    #{line}") }
  end

  def close
    @sink.close if @sink.respond_to?(:close)
  end

  private

  def dispatch(level, message)
    @sink.call(level, redact(message))
  end

  # URL 里可能带代理账号密码（http://user:pass@host），日志不落明文。
  def redact(message)
    message.to_s.gsub(%r{//[^/@\s]+@}, "//***@")
  end
end
