# 开发与运行手册

本手册是操作入口，详细业务边界见 [docs/specs/](../specs/)，系统链路见 [docs/architecture/README.md](../architecture/README.md)。

## 初始化与开发

```text
bundle install
bin/rails db:create db:migrate
bin/dev
```

本地开发账号和环境差异以 [README.md](../../README.md)、[config/environments/](../../config/environments/) 与 seed 为准；不要把开发凭据复制到生产配置。

Ruby 版本遵循 [.ruby-version](../../.ruby-version)；[bin/dev](../../bin/dev) 启动 Rails 和 Tailwind watch。Windows 下需要兼容项目脚本的 shell，明确区分 PowerShell 与 POSIX 环境变量语法。文档使用 UTF-8；不要将 GBK 输出按 UTF-8 保存，也不要把本机路径写成团队通用路径。

## Windows / WSL 与 Docker 本地核对

同一个 Windows checkout 在 WSL 下出现大量改动时，先区分内容、文件模式与换行符差异。可只读检查 `git ls-files --eol`、`git diff --ignore-space-at-eol --numstat`，再用 `git -c core.autocrlf=true -c core.filemode=false status --short` 与 Windows 状态比较。只有核对结果一致时，才能将多余改动归因为环境差异；不要批量还原文件或把整仓换行转换混进功能提交。

2026-10-18 本地核验中，WSL 的代表性文件在忽略行尾差异后没有内容变化，临时统一上述参数后的完整状态与 Windows 一致。后续该 checkout 的提交优先由 Windows Git 执行；本次没有修改持久 Git 配置。

Docker 验证先用 `docker version` 确认客户端和服务端均可用。2026-10-18 本机客户端可用，但 Docker Desktop Linux 引擎管道不存在，尚未启动容器或验证应用运行。

现有 [Dockerfile](../../Dockerfile) 面向生产，默认 production；[启动脚本](../../bin/docker-entrypoint) 在启动 Rails server 时会执行 `db:prepare`。本地验证应先准备隔离的 PostgreSQL 数据库和明确的开发/测试配置，避免直接挂接生产配置。开发环境还需核对依赖分组、源码脚本换行符和执行权限。建议后续使用独立的本地 Compose 配置承载应用与数据库，新增配置前另列文件清单，不改生产部署配置来适配本机。

## 最小验证顺序

1. 先运行受影响领域的 Minitest，例如账号、任务、爬虫、OAuth 或活动研究测试。
2. 运行 `bin/rails zeitwerk:check`，确认新增入口可自动加载。
3. 运行 [bin/rubocop](../../bin/rubocop)；安全相关改动再运行 [bin/brakeman](../../bin/brakeman) 和 `bundle exec bundle-audit check`。
4. 控制器、视图、Job、crawler 或路由影响用户流程时，先征得用户同意再运行 [bin/e2e](../../bin/e2e) 或定向 spec。E2E 是离线 mock 闭环，细节见 [e2e/README.md](../../e2e/README.md)。

纯文档变更只需检查链接、代码锚点、敏感信息、编码和差异，不必为此启动应用测试。涉及 crawler、API client、Job、认证、OAuth 或配置的改动，必须覆盖成功路径及相关失败/重试不变量。使用 Minitest，不引入 RSpec；需要时扩大到 `bin/rails test`，记录实际执行结果，不把计划运行写成通过。

Schema 变更应先准备可丢弃的测试数据库。POSIX shell 可用 `RAILS_ENV=test bin/rails db:prepare`；PowerShell 设置测试环境后运行 `bin/rails db:prepare`，并在完成后恢复原环境。先确认目标数据库，避免把开发或生产数据库当成测试库。

E2E 使用专用数据库（`E2E_DB_NAME`，默认 `mp_crawler_e2e`）和 `E2E_MOCKS=1`。新增外部端点，即使本轮不跑 E2E，也要补 [lib/e2e_mock/handlers.rb](../../lib/e2e_mock/handlers.rb) 和相应 fixture。现有 [e2e/README.md](../../e2e/README.md) 的“改完先跑”建议受 [AGENTS.md](../../AGENTS.md) 的用户授权要求约束。回归方式见 [.agents/skills/e2e-regression/SKILL.md](../../.agents/skills/e2e-regression/SKILL.md)；生产采样见 [.agents/skills/prod-sample/SKILL.md](../../.agents/skills/prod-sample/SKILL.md)，不得把真实样本入库。

## 调度与队列

- 生产 Active Job 使用 Solid Queue；周期任务见 [config/recurring.yml](../../config/recurring.yml)。
- 常规抓取由 `CrawlJob` 进入编排器；活动研究由 `EventResearchTaskJob` 进入独立编排器。
- 改调度前检查重复投递、任务提交时机、日预算、暂停/恢复和失败状态；不要在 HTTP 请求内同步执行网络抓取。

开发环境可能在进程内执行异步任务、使用内存缓存，不能据此推断生产队列可靠性或缓存持久性。查看 [config/environments/development.rb](../../config/environments/development.rb)、[config/environments/production.rb](../../config/environments/production.rb) 和实际 worker 状态，而非仅看控制台输出。

Kamal 部署配置在 [config/deploy.yml](../../config/deploy.yml)，不得编辑或暴露 `.kamal/secrets`。Docker 镜像将 `twitter-api-client` 安装到 `/rails/vendor/python`；变更 Python 依赖时需单独验证兼容性。仓库配置了 `main` 推送部署，文档 PR 的推送不等于授权部署。

## 新平台和导入扩展

新增常规抓取平台应有 Account STI 子类、`.crawler_class`、继承 `BaseCrawler` 的 crawler、需要的客户端/导入器，以及分发、失败和去重测试。研究型能力先判断是否需要独立任务，不要为了复用而接入文章抓取。

导入沿用 [app/services/accounts/](../../app/services/accounts/)、[app/services/rednote/](../../app/services/rednote/)、[app/services/twitter/](../../app/services/twitter/) 和 [app/services/website/](../../app/services/website/) 的既有模式；先核对 `AccountsController`、`AccountResolver`、路由和视图。平台错误回到对应导入页，错误展示需要截断和脱敏，不能把完整供应商异常塞入 Cookie flash。

需要扩展二维码登录时，先读 [app/services/qr_login.rb](../../app/services/qr_login.rb) 及其策略，复用 start/poll/save 的现有流程。浏览器登录看 [app/services/browser_login/](../../app/services/browser_login/)。进行中的会话、cookie jar 和二维码不能放进可提交文档或测试输出。

已有维护任务入口在 [lib/tasks/](../../lib/tasks/)：账号导入、日志清理、活跃度刷新、停更检查、WeRead 管理与网站监测。执行前阅读具体任务和参数，确认写入、网络请求及目标环境；不要把列出的任务当作例行必须执行的清单。

## 排错入口

- 抓取问题：先看 `CrawlTask`、`CrawlTaskAccount`、`CrawlLog`，再定位平台 crawler/API client。
- 正文缺失：区分文章列表是否成功与 `WechatContentDownloadJob` 是否失败，不要把缺正文误判成文章不存在。
- 网站问题：检查 `WebsiteAccount`、`MonitorPage`、页面版本/变化和发现日志。
- 活动研究问题：检查 `EventResearchTask`、成员状态、`EventResearchRun`、报告状态和外部查询缓存。
- OAuth/MCP 问题：检查 discovery、resource、scope、受众和调用审计记录；不要在日志中输出 token。

## 提交前文档核对

- 代码行为改变时更新对应 [docs/specs/](../specs/) 或记录差异，而不是默默让文档落后。
- 新增外部端点时补离线 mock/fixture；新增授权工具时补 scope 清单和测试。
- 检查 `git diff` 只包含批准文件；检查敏感信息、生产样本、本地路径和文档链接。

提交者负责说明“做了什么、学到了什么、实现是否偏离意图”；审阅者检查证据和未决事项。每次提交都检查文档影响，但无需为无行为变化的小改动制造变更记录。可复用的排错经验写入本手册，行为变化写入领域文档，重要决策写入 changelog。语义冲突必须提出，由人决定，不能靠自动覆盖规格解决。

当前没有自动文档检查 hook，CI 也未自动触发 PR 检查；这些是审阅约定，不是已强制执行的门禁。没有测试结果时明确写“未运行”及原因。

## 原有工程约束

- `CrawlTask`、`CrawlTaskAccount`、`CrawlLog`、`WechatContentDownloadTask` 是审计证据，不能作为一次性界面状态处理；正文任务的 job_id/heartbeat 用于重叠检测和接管。
- 记录提交后再投递 Job；维护暂停、恢复、分页、预算、阈值和并发上限。安全重投是需要测试证明的约束，不表示每个现有 Job 都已证明幂等。
- 原始上游响应按现有模型契约存储，保留数据来源；缺失与解析衍生值不能混淆。
- 密钥、代理、QR 登录会话、WeRead 账号池、第三方敏感响应不得出现在日志、错误、文档或测试输出。
- 审查优先级：认证与泄露 → 重复/过量抓取 → 归属/去重/时间/状态 → 恢复和审计 → 生产调度/队列/部署 → 测试是否证明不变量；格式问题不应掩盖实际风险。
- 临时调查与入门材料使用 `tmp/doc/`，脚本和运行产物使用 `tmp/` 其它位置；默认不提交。正式文档才进入已批准的 [docs/](..) 结构。

## 禁止事项

不提交真实 Cookie、API Key、OAuth token、`master.key`、数据库 URL、生产样本或 `docs/server-access.local.md`；不通过日志、异常或测试输出回显这些内容。
