# E2E 浏览器回归测试（离线闭环）

代替人工"打开浏览器点一遍"的回归验证：Playwright 驱动真实浏览器访问
development 环境的 Rails 应用，所有外部依赖（微信公众号平台、Dajiala、
TikHub、WeRead、Feishu、Twitter Python 客户端、Ferrum 无头浏览器）全部被
mock，测试结果以截图 + 视频 + trace 的 HTML 报告呈现。

## 快速开始

```bash
bin/e2e                    # 全量回归：清库重种 → 启动带 mock 的服务器 → 跑测试 → 出报告
npx playwright show-report # 交互式 HTML 报告（在 e2e/ 目录下执行）
```

首次运行会自动 `bundle install`、`npm install` 并下载 chromium。之后每次
全量回归约 30 秒，**全程不访问外网**。

每次跑完会生成 **`e2e/report.html` 结果入口页**：整体通过情况、每个用例的
状态与耗时、关键步骤截图、失败现场与录屏，双击即可打开（若浏览器不显示
截图/录屏，用 `python3 -m http.server -d e2e 8000` 后访问
`http://localhost:8000/report.html`）。它由自定义 reporter
（`e2e/support/summary-reporter.ts`）在运行结束时生成。

常用变体：

```bash
bin/e2e tests/05-crawl.spec.ts   # 只跑一个文件（验证某次改动）
bin/e2e --keep-db                # 不清库，只补种子（快速迭代）
bin/e2e --headed                 # 带 GUI 观看
bin/e2e --ui                     # Playwright UI 调试模式
```

## 它是如何做到离线的

| 依赖 | mock 方式 |
| --- | --- |
| weread.qq.com（WeRead 直连：扫码登录/最新文章/正文页） | WebMock 按 host 拦截，回放 `e2e/fixtures/weread_native/` 报文（`lib/e2e_mock/handlers.rb`，扫码状态机与微信侧同构） |
| mp.weixin.qq.com（搜号 / 文章正文 / get_mp_info） | 同上，回放 `e2e/fixtures/wechat_mp/`；weread_native 抓到的文章 link 指向 mp.weixin 地址，正文下载仍走这里 |
| Dajiala / TikHub / Rednote | 同上，按 `e2e/fixtures/<服务>/` 目录约定找文件 |
| Feishu 推送 | 一律返回成功 |
| Twitter（python3 子进程） | Ruby 层 prepend stub，回放 `e2e/fixtures/twitter/`（`lib/e2e_mock/ruby_stubs.rb`） |
| Serper 搜索 / LLM 代理 / 天眼查（活动调研） | WebMock 按 host 拦截，回放 `e2e/fixtures/event_research/`；调研抓取的目标页面在合成 host `news.e2e-event.test` 上回放 |
| Ferrum 真浏览器抓正文 | Ruby 层 stub 直接拒绝（HTTP 层已覆盖，触发即说明 fixture URL 形态不对） |
| 浏览器侧的外链图片 | helpers.ts 里 `context.route` abort 一切非 127.0.0.1:3001 的请求 |

- 抓取 provider 默认（且唯一）为 weread_native（直连微信读书）：列表走
  `/api/mp/cover`（每次仅最新一篇），文章 link 为原始 mp.weixin 地址，正文
  下载走 mp.weixin 的 `/s/<slug>` fixture。其余 provider 的 UI 已隐藏，
  `Option.wechat_api_provider` 会把历史遗留值按 weread_native 处理。

- mock 只在 `E2E_MOCKS=1` 且 development 环境生效（`config/initializers/e2e_mock.rb`），
  生产与单元测试完全不受影响。
- 未被 mock 的外部 host 会直接抛 `NetConnectNotAllowedError` —— 新引入的
  外部依赖会立刻暴露，这是设计而非缺陷。
- 扫码登录的状态机在 handlers 里：每次重置后第 1 次轮询 waiting → 第 2 次
  scanned → 第 3 次起 success，随后走完整的 bizlogin/home 链路落库会话。

## 数据隔离

- `bin/e2e` 用 `E2E_DB_NAME`（默认 `mp_crawler_e2e`）指向**独立数据库**
  （`config/database.yml` 的 development 段读取该变量），不碰开发数据。
- 重置用 `rake e2e:reset_db`（TRUNCATE 全表，对残留连接免疫，比
  db:drop 稳），再 `rake e2e:seed` 写入确定性种子（1 个公众号、mp_native
  已登录会话、SVG 素材）。
- `e2e/fixtures/samples/`（gitignore）存放生产样本数据（见 `.agents/skills/prod-sample/SKILL.md`），
  存在时种子与 mock 回放会自动采用。

## 报告

- `e2e/playwright-report/`：Playwright HTML 报告，**每个用例有视频**，
  关键步骤有全页截图（spec 里的 `shot()`），失败附 trace。
- `e2e/test-results/`：原始产物（error-context.md 有失败时的页面快照）。
- 两者都在 gitignore 里，不要提交。

## 目录结构

```
bin/e2e                  一键入口（bash）
lib/e2e_mock.rb          mock 层入口（WebMock 装配）
lib/e2e_mock/handlers.rb 按服务分发的响应处理器（加新端点在这里）
lib/e2e_mock/ruby_stubs.rb  非 HTTP 依赖的 Ruby 层 stub
lib/e2e/seeder.rb        种子数据（含生产样本导入）
lib/tasks/e2e.rake       seed / reset_db 任务
e2e/fixtures/            mock 报文（按服务分目录）
e2e/tests/*.spec.ts      回归用例（按领域编号）
e2e/support/helpers.ts   login/gotoAccounts/shot 等 fixture 与 helper
```

## 日常用法建议

- AI 改了控制器/视图/crawler 逻辑后：先 `bin/e2e`（或只跑相关文件）确认
  主流程没坏，再看 HTML 报告的截图确认视觉没坏。
- 给新流程加用例、给新外部端点加 mock 的方法，见
  `.agents/skills/e2e-regression/SKILL.md`。
