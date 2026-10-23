# 架构与运行边界

状态：当前实现基线（2026-10-16 核对）。本文件回答“代码如何连接”，不代替领域规格。

## 主要执行链

### 常规抓取

网页入口先创建 `CrawlTask` 再入队 `CrawlJob`；定时入口直接调用无任务 ID 的 `CrawlJob`，由 Job 选择到期账号并创建任务。随后 `CrawlOrchestrator` 初始化成员，按 `account.class.crawler_class` 调度，保存文章、统计和日志。编排调用返回后 `CrawlJob` 入队正文下载；不能据此断言原任务一定成功。

### 官网监测

Sitemap 路径：`WebsiteAccount` → `WebsiteCrawler::Discovery` → Fetcher → `WebsiteCrawler::ArticleSynchronizer` → 版本/变化/文章。Listing 路径：`WebsiteCrawler::ListingCrawler` → `ListingArticleSynchronizer` → 文章；列表入口不生成监测版本。这些类都位于 [lib/website_crawler.rb](../../lib/website_crawler.rb)。

### 活动研究

`EventAccount` → 创建 `EventResearchTask` → `EventResearchTaskJob` → `EventResearchTaskOrchestrator` 并发处理成员 → `EventResearchRun` 调用 [lib/event_research/](../../lib/event_research/) → `EventWeeklyDigestJob` 生成站内报告，定时任务按目标选择性推送飞书。

### 论文导入

`PapersController` 在事务中创建当前用户的 `PaperImportTask/Item`，提交后投递 `PaperImportJob`；Job 用数据库执行锁防止同任务重叠，逐项调用 `PaperImporter`。来源请求只到固定 arXiv/OpenReview API，解析后在事务中按来源 ID 写入共享 Paper、PaperSource 与有序署名；任务页面与轮询限定当前用户。arXiv 请求在串行锁内等待三秒，仍会占用连接，后续批量发现前须改为可调度的限流。当前没有作者订阅、元数据版本历史或定期同步；OpenReview 真实读取仍受 403 阻塞。详见 [论文规格](../specs/paper-tracking.md)。

arXiv 元数据导入完成后，按来源与版本创建 `PaperFullText` 并投递 `PaperFullTextDownloadJob`。`PaperFullTextDownloader` 独立下载 HTML、清理内容并缓存该版本的图片，和元数据请求共享来源锁；失败不影响已导入论文。全文文件置于 `storage/paper_full_texts`，数据库记录资源清单和状态。阅读和图片由登录后的 `PapersController` 提供，不直接暴露存储目录。全文版本保留不等于元数据历史快照；目前不提供自动文件回收。

作者关注从论文署名创建当前用户的 `PaperSubscription`；`PaperAuthorSyncJob` 按 arXiv `au:` 查询和 `start/max_results` 分页保存检查点。每页先在事务中导入共享论文和待确认匹配，再推进 `PaperSyncRun.next_offset`；失败不推进检查点。姓名命中证据和人工确认保存在 `PaperSubscriptionMatch`，确认后才安排全文下载。旧任务令牌会失效，用户只能访问自己的关注记录。

`SemanticScholarClient` 是尚未接入上述流程的只读试验适配器：按 arXiv 编号读取来源署名，再按来源作者 ID 获取资料，返回带观察时间的未确认身份证据，不落库、不绑定作者。客户端有单实例串行与有界同步重试，未来接入必须在后台任务执行，并另行处理跨进程冷却和证据持久化；不能从网页请求直接调用。当前验证限制见论文规格的 2026-10-23 记录。

### 访问与授权

网页 Session / API Key / Doorkeeper OAuth 分别进入对应控制器；MCP 在 `McpController` 中分流 OAuth 与 API Key，只有 OAuth 路径校验 scope 和 resource，再调用 [app/mcp_server/tools/](../../app/mcp_server/tools/)。具体兼容行为见访问领域文档。

## 数据关系

| 数据 | 关联与用途 | 源码 |
|---|---|---|
| Account / Article | 账号 STI 与文章归属；URL 唯一；活动账号不产出抓取文章 | [app/models/account.rb](../../app/models/account.rb)、[app/models/article.rb](../../app/models/article.rb) |
| CrawlTask / CrawlTaskAccount | 任务配置、成员进度和失败；CrawlLog 保存运行证据 | [app/models/crawl_task.rb](../../app/models/crawl_task.rb)、[app/models/crawl_task_account.rb](../../app/models/crawl_task_account.rb) |
| WebsiteAccount / MonitorPage / Version / Change | 官网账号关联页面、页面版本和变化 | [app/models/website_account.rb](../../app/models/website_account.rb)、[app/models/monitor_page.rb](../../app/models/monitor_page.rb) |
| EventResearchTask / TaskAccount / Run | 固定成员集合，成员关联当前运行；运行存 result JSON | [app/models/event_research_task.rb](../../app/models/event_research_task.rb)、[app/models/event_research_run.rb](../../app/models/event_research_run.rb) |
| EventWeeklyDigest | 任务级聚合报告；不是任意一周内所有运行的混合汇总 | [app/models/event_weekly_digest.rb](../../app/models/event_weekly_digest.rb) |
| Tag / Group / User | 账号标签、用户分组、关注标签与 RSS | [app/models/tag.rb](../../app/models/tag.rb)、[app/models/group.rb](../../app/models/group.rb)、[app/models/user.rb](../../app/models/user.rb) |
| ApiKey / DeviceCode / OAuth | 长期 API 凭据、设备码及 OAuth 授权；不同凭据路径不混用 scope | [app/models/api_key.rb](../../app/models/api_key.rb)、[app/services/mcp_oauth.rb](../../app/services/mcp_oauth.rb) |

完整字段和索引以 [db/schema.rb](../../db/schema.rb) 及迁移为准，不在文档复制一份容易漂移的 schema。

## 目录职责

- [app/models](../../app/models) 保持持久化和可审计状态；不要把长时间网络工作塞进模型回调。
- [app/jobs](../../app/jobs) 是异步边界；Job 必须能处理记录不存在、重复投递和晚到投递。
- [app/services](../../app/services) 负责编排导入、登录、OAuth 或外部能力的应用层流程。
- `lib` 放平台 crawler、API client、限流重试和研究领域逻辑；平台差异在这里隔离。
- [config/recurring.yml](../../config/recurring.yml) 定义周期性工作；生产使用 Solid Queue，不能把 Async 协程误认为队列替代品。

## 配置与外部依赖锚点

系统运行配置主要由 `Option` 读取，部署密钥由 `.kamal/secrets` 注入。外部依赖包括微信/微信读书、小红书/TikHub、Twitter Python 客户端、搜索服务、天眼查和飞书。文档只记录入口、用途与失败边界，不记录真实运行值。

| 上下文 | 代码锚点 | 排查时需确认 |
|---|---|---|
| 微信 provider 与会话 | [app/models/option.rb](../../app/models/option.rb)、[lib/weread_native_api_client.rb](../../lib/weread_native_api_client.rb) | 有效 provider 与历史存储值可能不同；会话是否有效 |
| 小红书 API/浏览器 | [app/models/rednote_account.rb](../../app/models/rednote_account.rb)、[lib/rednote_api_client.rb](../../lib/rednote_api_client.rb)、[lib/rednote_browser_crawler.rb](../../lib/rednote_browser_crawler.rb) | 实际分发路径、会话和供应商失败 |
| Twitter | [lib/twitter_api_client.rb](../../lib/twitter_api_client.rb)、[bin/twitter_fetch.py](../../bin/twitter_fetch.py) | Python 环境、依赖版本、Cookie 可用性 |
| 研究搜索/LLM | [app/jobs/event_research_job.rb](../../app/jobs/event_research_job.rb)、[lib/llm_client.rb](../../lib/llm_client.rb)、[lib/event_research/](../../lib/event_research/) | provider、环境变量与 Option 优先级、缓存刷新 |
| 企业信息 | [lib/event_research/tianyancha_client.rb](../../lib/event_research/tianyancha_client.rb) | 可选增强、失败和缓存，不把缺配置等同无企业 |
| 报告推送 | [app/models/event_weekly_digest.rb](../../app/models/event_weekly_digest.rb)、[app/jobs/event_weekly_digest_job.rb](../../app/jobs/event_weekly_digest_job.rb) | 全局活动目标、报告状态；区别扫码提醒目标 |
| 调度/队列 | [config/recurring.yml](../../config/recurring.yml)、[config/environments/production.rb](../../config/environments/production.rb) | 配置是否启用、worker 是否运行、环境与时区 |

仅凭仓库不能得知生产 Option 值、外部服务健康或部署版本。需要这些上下文时，说明缺口并使用获授权的只读方式按最小字段核对；不得导出整张 Option 表或把敏感值粘进文档。没有通用生产配置读取 MCP，不能把业务 MCP 当作配置查询工具。

开发使用内存缓存，生产配置 Solid Cache 与 Solid Queue。排错要记录环境和版本；“本机执行成功”不足以证明生产定时任务已运行。

## 数据不变量

`Article.url` 唯一；任务成员状态和日志是运行证据；账号统计与 `next_crawl_at` 不能因重复 Job 被错误覆盖；外部失败要能追溯到任务、账号或运行记录；并发必须受配置和平台限流约束。
