# 活动调研的异步执行：读取 EventResearchRun 与账号配置，组装 EventResearch 各组件
# 跑一轮调研，把结果 JSON 写回 run.result。
#
# 与抓取管线（CrawlJob / CrawlOrchestrator）完全独立 —— 调研不做文章同步，也没有
# 暂停/续传语义：失败直接重开一轮即可，已完成的中间产物（搜索/网页/LLM 缓存）都在
# 磁盘缓存里，重跑会快很多。
#
# 幂等性：mark_running! 只允许 pending → running 一次，重复投递的 job 会直接返回；
# 结果只写入本 run 行，不碰任何文章数据。
class EventResearchJob < ApplicationJob
  queue_as :default

  def perform(run_id)
    run = EventResearchRun.find_by(id: run_id)

    if run.nil?
      Rails.logger.info("EventResearchJob: EventResearchRun ##{run_id} no longer exists")
      return
    end
    return if run.completed?

    self.class.execute_run(run)
  end

  def self.execute_run(run)
    return unless run.mark_running!

    reporter = EventResearch::Reporter.new(EventResearch::CrawlLogSink.new(run))
    if (error = preflight_error)
      reporter.error("前置检查未通过：#{error}")
      run.mark_failed!(error)
      return
    end

    reporter.info("开始调研：#{run.account.nickname}#{run.refresh_cache? ? "（本次忽略缓存）" : ""}")

    cache = EventResearch::RunCache.new(root: cache_root(run), reporter: reporter, refresh: run.refresh_cache?)
    config = run.account

    result = EventResearch::Researcher.new(
      event: config.nickname,
      **config.research_config,
      search: search_client(cache: cache, reporter: reporter),
      pages: EventResearch::PageFetcher.new(cache: cache, reporter: reporter),
      llm: LlmClient.new,
      tianyancha: EventResearch::TianyanchaClient.new(api_key: Option.tianyancha_api_key, cache: cache, reporter: reporter),
      cache: cache,
      reporter: reporter
    ).run

    run.store_result!(result)
    run.reload

    if run.completed?
      reporter.info("调研完成：获奖 #{run.award_count} 条，人物 #{run.people_count} 人，公司 #{run.company_count} 家，结果已存入 run##{run.id}")
    else
      reporter.warn("调研结束但没有得到有效数据（#{run.error_message}）")
    end
  rescue StandardError => e
    reporter ||= EventResearch::Reporter.new(EventResearch::CrawlLogSink.new(run))
    reporter.error("调研失败: #{e.message}", exception: e)
    run.mark_failed!("#{e.class}: #{e.message}")
  end

  # 密钥缺失时尽早失败，给出可操作的指引。天眼查是可选增强，不在这里挡。
  def self.preflight_error
    return "未配置 LLM 密钥（openai_api_key），请先在 /admin/settings 配置" unless LlmClient.configured?

    if search_api_key.blank?
      return "未配置 #{search_provider_name} API 密钥，请先在 /admin/settings 配置 #{search_option_key}（或环境变量 #{search_env_key}）"
    end

    nil
  end

  def self.search_provider
    Option.event_search_provider
  end

  def self.search_provider_name
    search_provider == "tavily" ? "Tavily" : "Serper"
  end

  def self.search_option_key
    search_provider == "tavily" ? "tavily_api_key" : "serper_api_key"
  end

  def self.search_env_key
    search_provider == "tavily" ? "TAVILY_API_KEY" : "SERPER_API_KEY"
  end

  def self.search_api_key
    ENV[search_env_key].presence || Option.public_send(search_option_key)
  end

  def self.search_client(cache:, reporter:)
    client_class = search_provider == "tavily" ? EventResearch::TavilySearch : EventResearch::SerperSearch
    client_class.new(api_key: search_api_key, cache: cache, reporter: reporter)
  end

  def self.cache_root(run)
    Rails.root.join("tmp", "event_research", "run-#{run.id}")
  end
end
