---
name: e2e-regression
description: Run and extend mp-crawler's offline browser E2E regression suite (bin/e2e + Playwright). Use whenever the user wants to 跑回归 / 跑E2E / 端到端测试 / 浏览器自动化测试, verify a UI or crawl-flow change in a real browser, add new E2E specs, or get an HTML report with screenshots and videos of the main flows — even if they just say "测一下"、"回归一下"、"看看页面还能不能用".
---

# E2E 回归测试闭环

mp-crawler 的浏览器回归测试是一条完全离线的闭环：独立数据库 + 所有外部
HTTP 由本地 fixture 回放 + Playwright 产出截图/视频 HTML 报告。它代替人工
"打开浏览器点一遍"来验证主流程没被改坏。

## 覆盖的主流程（e2e/tests/）

1. 登录/登出（开发者快速登录，dev 环境专属）
2. 控制台统计
3. 帐号列表/详情 + 官网导入表单
4. 微信文章链接导入（后台任务解析文章页 → 帐号落库）
5. **微信抓取主链路**（provider 为 weread_native，直连微信读书）：触发抓取 →
   最新文章接口（mock weread.qq.com）→ 文章落库（link 指向原始 mp.weixin
   地址）→ 正文下载（mock HTTP）→ 详情页渲染
   （含"重复抓取不产生重复文章"的幂等回归）
6. 微信读书（直连）扫码登录全流程（mock 扫码状态机；其余 provider 的
   设置 UI 已隐藏）
7. RSS 输出 + API Key 创建 + Bearer 访问 /api/v1/articles
8. **活动研究全链路**（tests/08-event-research.spec.ts）：导入活动配置 →
   研究控制台启动调研（Serper/目标页面/LLM/天眼查全部 mock 回放）→
   结果 JSON 渲染与下载 → 忽略缓存重新启动产生新一轮运行

## 怎么跑

```bash
bin/e2e                                  # 全量回归（清库重种，最确定）
bin/e2e tests/05-crawl.spec.ts           # 只跑一个文件（迭代改动的首选）
bin/e2e --keep-db                        # 保留数据，只补种子
bin/e2e --headed                         # 带 GUI 看过程
bin/e2e --ui                             # Playwright UI 调试模式
```

- 跑完报告在 `e2e/playwright-report/`（含每个用例的视频、关键步骤截图、
  失败 trace）。**用 `npx playwright show-report` 打开**（file:// 打不开），
  这是给用户看的"人眼证据"，汇报结果时指给用户。
- 服务器日志在 `log/e2e-server.log`；单个用例的失败现场在
  `e2e/test-results/<用例>/error-context.md`（页面快照）和 trace.zip。
- 首次运行会自动 `npm install` + 下载 chromium；需要 Ruby gems、PostgreSQL 和
  Node，但**全程不需要外网**。

## 失败后的排查顺序

1. 先看 `error-context.md` 的页面快照 —— 多数失败是选择器没对上或页面没到
   预期状态，不是产品 bug。
2. `log/e2e-server.log` 里搜 `E2eMock` 或 `NetConnectNotAllowed` —— 出现后者
   说明代码新引入了外部 HTTP 依赖，fixture 没覆盖（这是测试在帮忙，不要
   绕过它）。
3. 任务推进慢不是 bug：抓取/正文下载靠 Rails 后台任务（dev 是进程内
   async 适配器），spec 里用 expect + timeout 等待。

## 为某次改动加回归用例

1. 按领域挑文件（01 认证、03 帐号、05 抓取链路、06 扫码、07 RSS/API），
   新增 test；改了哪个流程就在哪个文件里加，别新建孤立文件。
2. 选择器约定（从既有用例照抄）：
   - 登录用 `login(page)` helper（dev_login，自动建管理员）。
   - 进帐号列表必须用 `gotoAccounts(page)`——accounts#index 开启了
     QueryPersistenceConcern，会把上次的筛选条件按用户记在服务端缓存里，
     `reset=1` 先清掉，否则用例之间互相污染。
   - 按钮常有多处重名（列表行 + 卡片视图），用 `.first()` 避免 strict mode
     报错。
   - 文章标题链接是 `target="_blank"`，点开会弹新标签：用
     `const [p] = await Promise.all([page.waitForEvent("popup"), link.click()])`。
   - 任务页断言状态用 `page.locator('[data-task-status="completed"]')`。
   - 关键步骤调 `await shot("名称")` 截图进报告。
3. 用例涉及新的外部端点时，在 `lib/e2e_mock/handlers.rb` 加 handler、在
   `e2e/fixtures/<服务>/` 放报文（真实响应结构优先，可以从生产样本改）。
   mock 层的机制：`E2E_MOCKS=1` 时 WebMock 拦截全部外部 HTTP 按 host 分发，
   `config/initializers/e2e_mock.rb` 只在 development 生效——**不要**在
   production 或单元测试里打开它。
4. 用例要"真实数据"时，让用户跑 prod-sample skill（见该 skill），样本会
   自动进种子和 mock 回放。

## 红线

- 不要为了跑通测试禁用离线护栏（helpers.ts 里的 `context.route` abort）或
  放开 WebMock —— 测试永不触网是这套闭环的根基。
- 不要在 `RAILS_ENV=production` 下跑；`e2e:seed`/`e2e:reset_db` 自带
  `E2E_DB_NAME` 守卫，也不要帮人绕过。
- `e2e/fixtures/samples/`、`e2e/playwright-report/`、`e2e/test-results/` 都在
  gitignore 里，不要提交；samples 里是生产真实数据。
