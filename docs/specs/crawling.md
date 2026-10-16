# 多源内容抓取

状态：当前实现基线（2026-10-16 核对）。

## 已实现能力

- `Account` 是 STI 基类，当前常规采集平台包括 `WechatAccount`、`RednoteAccount`、`TwitterAccount` 和 `WebsiteAccount`。
- 账号可以从网页管理端导入、启停、分组、打标签和手动发起抓取；导入服务位于 [app/services/](../../app/services/) 下的平台导入模块。
- `Account#crawl!` 创建 `CrawlTask` 后入队 `CrawlJob`。`CrawlJob` 对指定任务或到期账号调用 `CrawlOrchestrator`。
- `CrawlOrchestrator` 按平台分发到 `BaseCrawler` 子类，在账号和文章两个层级使用并发控制，并记录平台级摘要、任务日志和错误计数。
- `CrawlTask` 状态为 pending/running/paused/completed/failed；成员 `CrawlTaskAccount` 状态为 pending/running/completed/failed，没有独立 paused 状态。任务支持暂停、恢复、失败成员重试和轮询查询。
- 文章以 `Article.url` 做唯一性约束，重复投递不能重复创建文章；正文下载与文章列表获取分开，由 `WechatContentDownloadJob` 和文章详情操作负责。
- 活跃度字段和 `next_crawl_at` 用于分层调度；定时 `CrawlJob` 只选取到期账号，并受各平台日预算约束。
- 微信、小红书和 Twitter 客户端各自处理认证、分页、限流和供应商错误；平台错误阈值可提前停止该平台剩余成员，不应改成全局静默成功。

## 当前微信入口

当前 `Option.wechat_api_provider` 对空值和历史提供方值归一为 `weread_native`，设置页主要使用微信读书直连会话。旧客户端仍保留，但仅修改其旧配置值不会恢复旧入口；不要把保留的实现视为当前可通过配置自由切换的提供方。

独立的 `WechatContentDownloadJob` 存在，但 [config/recurring.yml](../../config/recurring.yml) 中独立每日调度目前被注释；`CrawlJob` 调用编排器返回后会入队正文下载，不保证只有抓取成功才入队。另有正文下载任务与文章详情操作入口，不能假定两种操作走完全相同的 Job。修改调度前必须分别核对 Job、配置和测试。

## 调度与失败语义

到期账号按从未抓取、活跃度、逾期时间排序，每次选取受 `daily_crawl_budget_for` 限量；该限量不等于对一天所有手动重跑的总请求数实行扣账。抓取完成后的间隔来自 Account 的活跃度规则：active 1 天、slow 3 天、dormant 7 天、dead 21 天、never 30 天。

`CrawlOrchestrator` 为每个平台建立独立账号信号量，文章并发由具体 crawler 使用。通用 `Retryable` 对可重试错误退避，对密钥错误等直接抛出；微信会话失效、小红书缺密钥/余额不足可中断相应平台，Twitter 缺密钥还会向外抛出。不要用“任何凭据错误都暂停全任务”或“其它平台一定继续”概括全部路径。

任务页面通过 [app/javascript/controllers/task_poller_controller.js](../../app/javascript/controllers/task_poller_controller.js) 和控制器 poll 返回值更新；显示完成必须结合成员结果和日志，不能只看页面停止轮询。普通日志受 verbose 设置影响，强制用量摘要等审计日志例外。

## 关键边界

- 长时间网络工作只能在 Job/编排器内执行，控制器只创建任务或返回状态。
- 供应商返回未知、密钥失效、余额不足或会话失效时，任务必须留下可解释的失败/暂停证据。
- 限流和重试既有 HTTP 层中间件，也有应用层 `Retryable`；不要在控制器或循环中另加无界重试。
- 文章列表抓取成功不代表正文一定成功；正文缺失应保持可见并可重试。

## 代码与测试入口

- [app/models/account.rb](../../app/models/account.rb)、[app/models/crawl_task.rb](../../app/models/crawl_task.rb)、[app/models/crawl_task_account.rb](../../app/models/crawl_task_account.rb)、[app/models/article.rb](../../app/models/article.rb)
- [app/jobs/crawl_job.rb](../../app/jobs/crawl_job.rb)、[app/jobs/wechat_content_download_job.rb](../../app/jobs/wechat_content_download_job.rb)
- [lib/base_crawler.rb](../../lib/base_crawler.rb)、[lib/crawl_orchestrator.rb](../../lib/crawl_orchestrator.rb)、`lib/*_crawler.rb`、[lib/retryable.rb](../../lib/retryable.rb)
- [test/models/account_test.rb](../../test/models/account_test.rb)、[test/lib/rednote_crawler_test.rb](../../test/lib/rednote_crawler_test.rb)、[test/lib/wechat_crawler_content_download_test.rb](../../test/lib/wechat_crawler_content_download_test.rb)

## 变更验证关注点

账号分层与 scope 一致；重复文章不新增、不改变错误归属；时间缺失不变成 epoch；恢复不重跑已完成成员；供应商错误保留可追踪状态并尊重限流。这些是改动时要证明的条件，不能从测试文件存在推断所有条件已覆盖。
