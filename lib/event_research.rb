# 活动调研（Event Research）：输入一个活动名 → Tavily/Serper 搜索 → 抓取结果页
# → LLM 抽取获奖人/项目 → 天眼查补全机构工商档案 → 对每个人再搜一轮补充资料
# → 得到结构化 JSON 结果。
#
# 这套流程与文章抓取（BaseCrawler / CrawlTask / CrawlOrchestrator）完全独立：
# 调研是低频、手动触发、以「产出一份可复核的 JSON 数据」为目的的操作，
# 结果落在 EventResearchRun.result（jsonb），通过 API / MCP 对外提供。
#
# 各模块：
#   Reporter          运行日志（sink 可插拔：CLI 写 stdout+文件，应用写 CrawlLog）
#   CrawlLogSink      应用侧的 Reporter sink
#   RunCache          断点续跑的磁盘缓存（按 namespace 分 TTL）
#   SerperSearch      Serper（Google）搜索
#   TavilySearch      Tavily 搜索
#   PageFetcher       网页正文抓取（复用 WebsiteCrawler::Fetcher/Extractor）
#   TianyanchaClient  天眼查工商档案（按次计费，带单次运行上限）
#   Researcher        主流程编排
#
# CLI 入口见 script/event_research.rb；应用侧由 EventResearchJob 驱动。
module EventResearch
  autoload :Intelligence, "event_research/intelligence"
  autoload :WeeklyDigestBuilder, "event_research/weekly_digest_builder"
  autoload :WeeklyDigestText, "event_research/weekly_digest_text"
  # 缓存有效期（秒）。search 是约定好的 1 天；网页正文一周内基本不变；
  # LLM 抽取最贵，留一周，隔天重跑也能直接命中。
  # 天眼查按次计费，而工商登记信息变化极慢，所以缓存留得最激进（30 天）——
  # 同一个活动反复调研，机构档案只会在第一次真花钱。
  CACHE_TTLS = {
    "search" => 24 * 60 * 60,
    "document" => 7 * 24 * 60 * 60,
    "llm" => 7 * 24 * 60 * 60,
    "tianyancha" => 30 * 24 * 60 * 60
  }.freeze

  # 正文抽取口径（截断长度 / 取正文的规则）变化时递增，避免复用旧口径的缓存。
  DOCUMENT_VERSION = "v2"
  # 单篇正文上限；整体 prompt 另有 MAX_PROMPT_CHARS 预算，超出会丢尾部文档。
  MAX_DOC_CHARS = 50_000
  MAX_PROMPT_CHARS = 400_000
  # 短于这个长度的正文基本是 JS 空壳，喂给 LLM 只是浪费 token。
  MIN_DOC_CHARS = 80
  MAX_FETCH_FAILURES = 50
  # 网页抓取并发数（Async::Semaphore 的上限）。
  # 与应用内的抓取并发一样是「有上限的并发」：目标是别让几十个不同站点的页面串行等超时，
  # 又不至于一次打出太多连接触发反爬。
  FETCH_CONCURRENCY = 5

  def self.slug(value)
    slug = value.to_s.downcase.gsub(/[^\p{Han}\p{L}\p{N}]+/u, "-").gsub(/\A-+|-+\z/, "")
    slug.empty? ? "event" : slug
  end

  # 模型被超长 prompt / 截断搞崩时会返回一个空壳。这种结果不写缓存（下次重跑会重试），
  # 应用侧也不会把它当成一次成功的调研。
  def self.degenerate_result?(data)
    data.blank? || (
      data["awards"].to_a.empty? &&
      data["people"].to_a.empty? &&
      data.dig("intelligence", "people").to_a.empty? &&
      data.dig("intelligence", "projects").to_a.empty? &&
      data.dig("intelligence", "awards").to_a.empty? &&
      data["person"].blank?
    )
  end
end
