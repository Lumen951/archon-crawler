# 业务规格地图

本目录描述“系统要支持的业务边界”和当前实现基线。四份领域文档先以实现基线为主；其中未从代码和测试确认的产品意图会明确标记为待确认。

## 领域

| 领域 | 文档 | 主要入口 |
|---|---|---|
| 多源内容抓取 | [crawling.md](crawling.md) | `Account`、`CrawlJob`、`CrawlOrchestrator` |
| 官网监测 | [website-monitoring.md](website-monitoring.md) | `WebsiteAccount`、`WebsiteCrawler`、`ArticleSynchronizer` |
| 活动研究 | [event-research.md](event-research.md) | `EventAccount`、`EventResearchTaskJob`、研究服务 |
| 访问与交付 | [access-and-delivery.md](access-and-delivery.md) | Session、API、RSS、`McpController`、OAuth |

## 规格生命周期

- **草案**：探索中的问题或蓝图，不作为当前行为承诺。
- **Feature**：已确认的业务能力，写清范围、边界和验收条件。
- **Patch**：对 Feature 的局部替代；Patch 开头写覆盖范围，主文档反向链接 Patch。
- **Sunset**：功能下线的冻结说明、迁移决策和清理条件。

当前四份文档均是“当前实现基线”，不是未经确认的产品蓝图。新增产品需求前，先把意图、范围和验收条件补齐，再决定是否升格为 Feature。

每份新增规格至少写清：状态、需求来源、目标/非目标、角色与页面入口、数据和任务边界、正常/失败行为、验收条件、代码与测试锚点、未决问题。保存需求确认依据，不能把代码推测标成用户原意。

小变更直接更新主文档；只有需要独立评审或并行演进才拆 Patch，创建前列明文件范围。Patch 自身要能独立读懂，说明原行为、新行为、覆盖段落、迁移和验证；主文档在受影响段落声明被哪个 Patch 替代。稳定后收敛生效规则，避免读者必须追逐多层补丁。

Sunset 应记录冻结时间、替代方案、兼容期、迁移验收和清理条件；冻结后不继续叠加新功能。历史需求保留至排查和迁移不再依赖它，不自动删除。

## 页面与验证地图

| 领域 | 用户入口 | 代表性验证入口 |
|---|---|---|
| 抓取 | `/accounts`、`/accounts/import`、`/crawl_tasks`、`/wechat_content_download_tasks` | [test/models/account_test.rb](../../test/models/account_test.rb)、[test/lib/wechat_crawler_content_download_test.rb](../../test/lib/wechat_crawler_content_download_test.rb) |
| 官网 | `/accounts/import/website`、`/monitor_pages/:id`、`/monitor_changes` | [test/lib/website_listing_crawler_test.rb](../../test/lib/website_listing_crawler_test.rb)、[test/lib/article_synchronizer_test.rb](../../test/lib/article_synchronizer_test.rb) |
| 研究 | `/event_accounts/:id`、`/event_research_tasks`、`/event_weekly_digests` | [test/models/event_research_task_test.rb](../../test/models/event_research_task_test.rb)、[test/jobs/weekly_event_research_job_test.rb](../../test/jobs/weekly_event_research_job_test.rb) |
| 访问 | `/session/new`、`/profile`、`/rss`、`/api-docs`、`/mcp` | [test/services/mcp_oauth_test.rb](../../test/services/mcp_oauth_test.rb)、[test/integration/event_research_api_test.rb](../../test/integration/event_research_api_test.rb) |

实际路径和 HTTP 方法以 [config/routes.rb](../../config/routes.rb) 为准；表中只列导航，不授予调用权限。

## 验收约定

领域文档中的代码路径和测试路径用于定位验证，不表示本次编辑已经运行全部测试。涉及外部服务的测试必须离线 stub/mock；涉及数据、任务或权限的变更必须同时覆盖成功和失败/重试边界。
