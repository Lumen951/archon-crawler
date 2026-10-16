# AGENTS.md

本文件是 Agent 进入本仓库的入口地图（只导航，不堆叠细节）。先阅读本文件，再按任务进入 [docs/](docs/) 和代码入口。

## 项目定位

MP-Crawler（Archon）是 Ruby on Rails 8.1 多源内容与研究平台，采集微信公众号、小红书、Twitter/X 和官网内容，并提供网页、RSS、REST API 与 MCP 接入。生产环境使用 PostgreSQL、Solid Queue、Solid Cache、Solid Cable 和 Kamal。

## 文档地图

- 要了解当前业务边界：先读 [docs/specs/README.md](docs/specs/README.md)，再进入对应领域文档。
- 要了解代码如何协作：读 [docs/architecture/README.md](docs/architecture/README.md)。
- 要开发、验证或排错：读 [docs/runbook/README.md](docs/runbook/README.md)。
- 要追溯文档治理与重要变化：读 [docs/changelog/README.md](docs/changelog/README.md)。
- MCP 接入细节：[docs/mcp.md](docs/mcp.md)；天眼查接口资料：[docs/tianyancha_api.md](docs/tianyancha_api.md)。
- 浏览器回归：[e2e/README.md](e2e/README.md)；现有 Agent 技能：[.agents/skills/](.agents/skills/)。

## 仓库地图

- [app/models](app/models)：持久化、校验、关联和任务状态转换。
- [app/jobs](app/jobs)：抓取、正文下载、活动研究、定时检查等异步边界。
- [app/services](app/services)：导入、账号解析、二维码登录、MCP OAuth 等应用服务。
- [lib/](lib/)：`BaseCrawler`、平台爬虫、API 客户端、重试与限流、活动研究编排。
- [app/controllers](app/controllers)：网页、管理端、REST API、MCP/OAuth 入口；控制器不承载长时间网络抓取。
- [config/recurring.yml](config/recurring.yml)、[config/deploy.yml](config/deploy.yml)、[Dockerfile](Dockerfile)：生产调度与部署，修改前必须核对运行影响。

## 关键约定

- `Account` 是 STI 基类；常规抓取平台通过 `.crawler_class` 接入 `CrawlOrchestrator`。`EventAccount` 是活动研究配置，不进入常规抓取管线。
- `Account#crawl!` 只创建 `CrawlTask` 并入队 `CrawlJob`；网络抓取由 Job/编排器执行，不得放回 HTTP 请求。
- `CrawlJob` 委托 `CrawlOrchestrator`，文章列表获取与 `WechatContentDownloadJob` 正文下载保持分离。
- 保持 `Article.url` 唯一性、重复投递安全、分页/限流/错误阈值、暂停恢复和任务日志证据。
- 网站监测的 `MonitorPage`、`MonitorPageVersion`、`MonitorChange` 只用于官网监测，不要套用到其它账号类型。
- 外部失败必须留下真实的任务或账号失败状态；未知的供应商结果不得报告为成功。
- 解析时间必须先校验；缺失或非法时间保持 `nil` 或显式失败，不得静默变成 Unix epoch。
- 不得提交或打印 Cookie、API Key、OAuth token、数据库 URL、`master.key`、生产样本或飞书密钥。
- 记录提交后才能入队；不得因重试、重复或晚到 Job 破坏账号统计、任务成员和正文下载的审计记录。
- 保留 OAuth scope、resource/audience、PKCE、token 摘要及写工具授权；不得只凭客户端身份授权写入。
- 原始上游数据只存入既有模型约定的位置，保留缺失值与解析衍生值的来源差别；禁止无界并发。
- 修改配置、调度、认证、爬虫、Job 或 MCP 授权时，先读相关实现与测试，并补充成功和失败路径验证。

## 常用验证

```text
bin/rails test test/models/account_test.rb
bin/rails test test/lib/article_synchronizer_test.rb
bin/rails zeitwerk:check
bin/rubocop
bin/brakeman
bundle exec bundle-audit check
```

按需运行 `bin/rails test`；浏览器 E2E 只在用户要求或完成影响用户流程的改动后征得同意再运行。测试外部服务必须使用 stub/mock，不依赖真实凭据。

## 修改与提交流程

1. 先确认数据结构、目录归属和业务意图；不确定时停止并询问。
2. 先读将要修改的文件，保持改动小而可回溯；不要覆盖工作区中与本任务无关的修改。
3. 代码改变行为时同步检查对应 [docs/specs/](docs/specs/) 与 [docs/architecture/](docs/architecture/)；需求与实现不一致时列出差异，不擅自把规格改成代码。
4. 提交前检查 `git diff`、敏感信息、文档链接和验证结果；生产部署由合并到 `main` 的流程负责。
5. 创建文件/目录前列出清单征得同意；多步骤任务按阶段验收，除非用户明确授权连续完成。
6. 临时分析与入门材料放 `tmp/doc/`，调查脚本和运行产物放 [tmp/](tmp/) 的其它位置；不自动提交临时文件。

## 审查重点

依次检查凭据/授权、重复或过量抓取、文章归属/去重/时间/状态、暂停恢复与审计、生产队列调度部署、测试是否证明不变量。不要把主观格式意见置于具体风险之前。完整工程约束见 [运行手册](docs/runbook/README.md)。
