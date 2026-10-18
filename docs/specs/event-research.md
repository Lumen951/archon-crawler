# 活动研究

状态：当前实现基线（2026-10-16 核对）。

## 已实现能力

- `EventAccount` 是账号 STI 子类，但明确不进入 `CrawlTask`、`CrawlOrchestrator` 和常规文章抓取；它保存事件名、关键词、研究目的、指定页面及推送目标等 `event_config`。
- 活动详情页可以启动单次研究；研究任务也支持选定活动或全部活动，并通过 `EventResearchTask` 固定成员快照。
- `EventResearchTaskJob` 委托 `EventResearchTaskOrchestrator`，按配置并发执行 `EventResearchRun`，保存成员级完成、失败、跳过、进度和日志状态，支持暂停、恢复和失败重试。
- 研究服务组合搜索、页面抓取、企业信息查询、缓存和情报整理；外部资料与天眼查接口说明见 [docs/tianyancha_api.md](../tianyancha_api.md)。
- `WeeklyEventResearchJob` 每周为启用且账号处于 active 的活动创建定时任务；同一周通过 `source + schedule_key` 唯一约束避免重复任务，并强制刷新缓存。
- `EventWeeklyDigestJob` 为结束任务生成站内报告。手动研究不自动推送；定时研究使用 `EventWeeklyDigest.feishu_target` 读取全局活动研究目标。账号虽有独立目标字段，但聚合报告不按账号目标分发，也不回退到扫码提醒目标。发送失败会记录报告状态和错误。
- 报告可以重新生成或显式重发；重新生成基于任务成员当前关联结果，不重新研究、不自动推送。活动详情还可下载单次运行 JSON，不等于通用批量导出。
- 研究运行结果可通过网页、活动报告页面和 `api/v1/event_research_runs` 查询；MCP 也提供只读研究结果工具。

## 与常规抓取的区别

活动研究不是文章抓取的另一种平台。它没有 `crawler_class` 抓取文章，也不参与账号到期调度；研究任务、运行记录、报告和飞书推送使用独立模型与 Job。

任务暂停阻止后续成员启动，已经开始的活动会继续结束；单次运行不是可断点暂停的任务。恢复重置失败及遗留运行成员，已完成成员保留。同一活动只能有一条 pending/running 记录；重复运行竞争会记为跳过。没有提取到有效人物/获奖数据的退化结果仍保存，但标记失败。

研究用量来自成员当前关联运行结果中的搜索/天眼查统计，不等于供应商账单总额。LLM 和搜索密钥是研究前置条件，天眼查是可选增强。

## 代码与测试入口

- [app/models/event_account.rb](../../app/models/event_account.rb)、[app/models/event_research_task.rb](../../app/models/event_research_task.rb)、[app/models/event_research_run.rb](../../app/models/event_research_run.rb)、[app/models/event_weekly_digest.rb](../../app/models/event_weekly_digest.rb)
- [app/jobs/event_research_task_job.rb](../../app/jobs/event_research_task_job.rb)、[app/jobs/weekly_event_research_job.rb](../../app/jobs/weekly_event_research_job.rb)、[app/jobs/event_weekly_digest_job.rb](../../app/jobs/event_weekly_digest_job.rb)
- [lib/event_research_task_orchestrator.rb](../../lib/event_research_task_orchestrator.rb)、[lib/event_research/](../../lib/event_research/)
- [test/models/event_account_test.rb](../../test/models/event_account_test.rb)、[test/models/event_research_task_test.rb](../../test/models/event_research_task_test.rb)、[test/jobs/weekly_event_research_job_test.rb](../../test/jobs/weekly_event_research_job_test.rb)、[test/jobs/event_weekly_digest_job_test.rb](../../test/jobs/event_weekly_digest_job_test.rb)

## 待确认

高校专业分布数据、活动分析看板的指标和受众，以及研究报告的长期产品形态仍未确认；它们不应被当作当前已交付能力。
