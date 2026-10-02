# 应用侧的 Reporter sink：把调研过程写进多态 CrawlLog（loggable = EventResearchRun），
# 同时镜像一行到 Rails.logger。
#
# 调研是手动触发的低频操作，过程日志就是它唯一的运行凭证（跑了哪些搜索、
# 抓了哪些页面、LLM 每一步的产出），所以 info/warn/error 强制落库，不依赖
# verbose 开关；debug 只在 Option.verbose_mode? 打开时落库。
class EventResearch::CrawlLogSink
  def initialize(run, logger: Rails.logger)
    @run = run
    @logger = logger
  end

  def call(level, message)
    @logger.public_send(level, "[EventResearch] run##{@run.id} #{message}")
    CrawlLog.log(@run, level, message, force: level != :debug)
  end
end
