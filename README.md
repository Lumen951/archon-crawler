# archon-crawler

archon-crawler 是源策未来（ARCHON）的多源内容与研究追踪平台，基于 MP-Crawler 演进。它既采集微信公众号、小红书、Twitter/X 和官网内容，也支持活动研究与研究报告，并通过网页、RSS、REST API 和 MCP 提供访问。

## 当前项目理解

当前系统有两条主要工作链：**内容采集**把账号或官网内容转为文章与页面变化记录；**活动研究**围绕关键词、指定页面和研究目的生成研究结果与报告。二者共享账号管理和部分基础设施，但使用独立的任务与运行记录。

以下能力已在当前仓库中有实现；这是源码核对结果，不代表已完成生产环境验收。

| 领域 | 已有能力 | 详细说明 |
|---|---|---|
| 账号与采集 | 平台导入、账号启停、批量操作、文章去重、异步任务、暂停恢复、活跃度分层调度、微信正文下载 | [抓取基线](docs/specs/crawling.md) |
| 官网监测 | Sitemap 发现、列表规则、页面版本、内容变化、文章同步和监测 RSS | [网站基线](docs/specs/website-monitoring.md) |
| 活动研究 | 单个/批量研究、周期研究、成员进度、缓存与查询用量、研究结果、聚合报告、报告重生成与飞书推送 | [研究基线](docs/specs/event-research.md) |
| 组织与交付 | 标签、分组、关注标签、网页查询、RSS、REST API、MCP 研究结果查询 | [访问与交付](docs/specs/access-and-delivery.md) |
| 认证与管理 | 密码与 Magic Link、角色、API Key、OAuth/PKCE、管理员设置与调用记录 | [访问与交付](docs/specs/access-and-delivery.md) |

高校专业分布数据、活动分析看板、全文搜索、批量导出和抓取邮件通知仍属于[历史待确认事项](docs/changelog/README.md)，不作为已批准路线图。

## 技术与运行环境

- Ruby 版本以 [.ruby-version](.ruby-version) 为准，当前为 3.3.4；应用使用 Rails 8.1 和 PostgreSQL。
- 前端采用 Turbo、Stimulus 和 TailwindCSS。
- 生产 Active Job 使用 Solid Queue；Async 用于任务内部并发，不替代队列。
- 平台 API 客户端、限流和重试主要位于 [lib/](lib/)；Twitter 依赖 Python 客户端。
- 部署使用 Kamal；配置入口见 [架构说明](docs/architecture/README.md)。

## 本地开发

先准备匹配版本的 Ruby、Bundler 和 PostgreSQL，并检查本地数据库配置。下列初始化命令面向开发环境，会创建或更新本地数据库：

```sh
bundle install
bin/rails db:create db:migrate
bin/rails db:seed
bin/dev
```

开发/测试环境可使用登录页的 Archon Developer 入口（`developer@archon.test`）。Seed 不提供固定默认密码，生产环境不创建该默认账号。平台采集还需要管理员按实际环境配置外部服务会话或密钥；不要在文档中保存真实值。

Shell 脚本的运行环境需支持项目所用工具；Windows 下请确认 Ruby、Python、数据库和 shell 的路径、编码与运行环境一致，不要把 GBK 终端输出直接写回 UTF-8 文档。

## 使用入口

- `/accounts/import`：选择平台导入账号；官网与活动研究有各自的导入入口。
- `/crawl_tasks`：常规抓取任务、进度、日志和暂停/恢复。
- `/event_research_tasks`、`/event_weekly_digests`：研究任务与聚合报告。
- `/admin/settings`：管理员配置平台会话、限流、研究与飞书设置。
- `/rss`：RSS；`/api-docs`：REST API；`/mcp`：MCP 接入指引。

完整路由以 [config/routes.rb](config/routes.rb) 为准。生产环境已部署哪些能力、外部凭据是否有效，需要另外核验，不能仅由源码推断。

## 文档与协作

- [文档总索引](docs/README.md)：阅读路径、当前项目理解与文档维护规则。
- [业务地图](docs/specs/README.md)：四个领域的行为、边界和验证入口。
- [架构](docs/architecture/README.md)：数据与执行链、环境差异和外部上下文。
- [运行手册](docs/runbook/README.md)：开发、排错、验证与提交检查。
- [变更记录](docs/changelog/README.md)：治理基线与历史待确认事项。
- [MCP 接入资料](docs/mcp.md)、[天眼查接口资料](docs/tianyancha_api.md)：保留的专题文档。
- [Agent 入口](AGENTS.md)：编码规则；[离线 E2E](e2e/README.md)：浏览器回归说明。

## 验证与交付

项目采用 Rails Minitest，先运行受影响领域的测试。浏览器 E2E 按用户授权运行，外部调用应由 mock/fixture 隔离。

当前 CI 工作流只支持手动触发；`main` 推送配置了部署工作流。功能和文档改动先通过独立分支与 PR 审查，不能把“推送成功”当成测试通过或部署完成。
