# MP-Crawler

微信公众号和小红书文章爬虫 & RSS 订阅服务

## 项目简介

MP-Crawler 是一个基于 Ruby on Rails 的应用，用于自动抓取微信公众号和小红书文章，并提供 RSS 订阅服务。主要面向高校帐号，支持多平台、进度保存、断点续传、并发控制等功能。

## 技术栈

- **Framework**: Ruby on Rails 8.1
- **Database**: SQLite3 (solid_cache, solid_queue, solid_cable)
- **CSS**: TailwindCSS with CSS custom properties
- **Concurrency**: Async gem with Semaphore (runs in Puma process)
- **Frontend**: Stimulus.js, Turbo (Turbo Streams for real-time UI updates)
- **HTTP Client**: Faraday with faraday-retry
- **Pagination**: Kaminari
- **Search**: Ransack
- **Authentication**: has_secure_password + magic link login

## 核心功能

### 1. 多平台帐号管理
- 支持微信公众号（WechatAccount）和小红书（RednoteAccount）两种平台
- 使用 STI（Single Table Inheritance）模型：`Account` 基类，`WechatAccount` / `RednoteAccount` 子类
- 从 JSON 文件导入帐号列表（支持粘贴或上传）
- 从 API 搜索帐号并导入（微信公众号搜索）
- 网页界面导入：支持 JSON 文本、文件上传、搜索导入
- 命令行导入：`rails import:accounts`
- 查看帐号详情和文章列表（支持分页和 Ransack 搜索）
- 设置帐号状态（active/inactive）
- 手动触发抓取

### 2. 文章抓取
- **微信公众号**：使用 WeChat Article Exporter API（`down.mptext.top`）
- **小红书**：使用第三方 API（`api.yddm.com`）
- 异步并发抓取（可配置帐号并发数和文章并发数）
- 支持暂停和恢复
- 自动保存进度，支持断点续传
- 重复文章自动跳过（URL 唯一索引）
- 统一重试机制（`Retryable` 模块，指数退避）
- 错误阈值保护（累计错误 >= 20 自动终止任务）

### 3. 抓取任务管理
- `CrawlTask`：抓取任务，支持 pending/running/paused/completed/failed 状态
- `CrawlTaskAccount`：按帐号追踪抓取状态，支持独立重试失败帐号
- `CrawlLog`：结构化日志记录
- Turbo Streams 实时广播任务进度到 UI
- 按帐号并发和文章并发分别控制
- 自动重试：若有帐号抓取失败，自动调度重试（最多 5 次，指数退避）

### 4. 抓取日志
- `CrawlLog`：结构化日志记录（debug/info/warn/error）
- 仅在 `verbose_mode` 开启时写入日志
- 支持日志清理（按保留天数配置）

### 5. RSS 订阅
- 全局 RSS feed：`/rss`（支持按时间段过滤：today/yesterday/7days/1month）
- 单帐号 RSS feed：`/rss/{fakeid}`
- 帐号列表 RSS：`/rss/accounts`、`/rss/accounts/active`
- 自动包含最近 50 篇文章

### 6. 用户认证与权限
- 基于 `has_secure_password` 的密码认证
- **MiraclePlus OAuth 登录**（推荐）
- Magic Link 邮箱登录（免密码）
- 开发环境 dev_login 快捷登录
- 角色系统：admin / user（首个 OAuth 用户自动成为 admin）
- 邮箱验证机制
- `AdminMailer`：邀请邮件、登录链接邮件、新用户凭据邮件

### 7. API Key 管理
- **微信公众号**：`wechat_api_key`，有效期 4 天，支持过期检测和即将过期警告
- **小红书**：`rednote_api_key`，无过期机制
- 在 `/admin/settings` 页面统一管理

## 架构设计

### 数据模型

```
Account (帐号 - STI 基类)
├── WechatAccount (微信公众号)
├── RednoteAccount (小红书)
├── has_many :articles
├── enum status: { active: 0, inactive: 1 }
├── self.crawler_class (子类各自返回对应的 Crawler，供 CrawlOrchestrator 分发)
└── scope :active, :needs_crawling, :recently_crawled

Article (文章)
├── belongs_to :account
├── belongs_to :crawl_task (optional)
├── validates :url, uniqueness: true
├── raw_data (json - 原始 API 响应数据，微信为文章列表项，小红书为笔记详情完整响应)
└── scope :recent, :today, :yesterday, :last_7_days, :last_month

CrawlTask (抓取任务)
├── has_many :crawl_logs
├── has_many :crawl_task_accounts
├── has_many :articles
├── enum status: { pending: 0, running: 1, paused: 2, completed: 3, failed: 4 }
├── ERROR_THRESHOLD = 200
├── MAX_RETRIES = 5
└── retry_count (自动重试次数，指数退避调度)

CrawlTaskAccount (帐号抓取状态)
├── belongs_to :crawl_task
├── belongs_to :account
├── enum status: { pending: 0, running: 1, completed: 2, failed: 3 }
└── scope :incomplete

CrawlLog (抓取日志)
├── belongs_to :crawl_task
├── LEVELS: debug, info, warn, error
└── 仅在 verbose_mode 开启时写入

Option (系统配置 - key-value 存储)
- wechat_api_key / wechat_api_key_expires_at
- rednote_api_key
- default_article_concurrency / default_account_concurrency
- max_crawl_pages / crawler_verbose_mode

User (用户)
├── enum role: { user: 0, admin: 1 }
├── has_many :sessions
├── has_secure_password
└── magic link / email confirmation / password reset tokens
```

### 核心服务

**CrawlOrchestrator** (`lib/crawl_orchestrator.rb`)
- 统一的抓取调度器：一个 `Async::Semaphore` 循环内交替抓取**所有平台**的帐号（微信、小红书、未来的其他平台），而不是先抓完一个平台再抓下一个
- 按 `account.class.crawler_class` 把每个帐号分发给对应平台的 Crawler
- 负责暂停/恢复/错误阈值终止/自动重试调度等任务级别的通用逻辑
- 捕获 `CrawlerApiKeyError`（见下）并将任务置为 paused，不影响其他帐号继续抓取

**BaseCrawler** (`lib/base_crawler.rb`)
- 所有平台 Crawler 的基类，只定义一个接口：`self.crawl_account(account, crawl_task, article_concurrency:, max_pages:)`
- 平台 Crawler 只需实现「如何抓取单个帐号」，不再关心跨帐号的并发调度（由 `CrawlOrchestrator` 统一负责）

**CrawlerApiKeyError** (`lib/crawler_api_key_error.rb`)
- 各平台 API 密钥错误的通用 mixin（`include CrawlerApiKeyError`）
- `Retryable` 和 `CrawlOrchestrator` 通过它统一识别"密钥缺失/过期"类错误并立即失败/暂停任务，无需逐个平台硬编码错误类

**WechatApiClient** (`lib/wechat_api_client.rb`)
- 封装微信文章导出 API（`down.mptext.top`）
- 认证方式：`X-Auth-Key` header
- 主要接口：`get_articles`、`download_content`
- 自定义错误类：`ApiError`、`ApiKeyExpiredError`（包含 `CrawlerApiKeyError`）、`ApiRateLimitError`

**WechatCrawler** (`lib/wechat_crawler.rb`, `< BaseCrawler`)
- 抓取单个微信公众号：分页获取文章列表 → 下载正文（Markdown/HTML）→ 保存
- 帐号内部使用 `Async::Semaphore` 控制文章级并发
- 使用 `Retryable` 模块处理重试

**RednoteApiClient** (`lib/rednote_api_client.rb`)
- 封装小红书 API（`api.yddm.com`）
- 认证方式：`X-API-Key` header
- 主要接口：`get_user_notes`、`get_note_detail`
- 自定义错误类：`ApiError`、`ApiKeyMissingError`（包含 `CrawlerApiKeyError`）、`ApiRateLimitError`

**RednoteCrawler** (`lib/rednote_crawler.rb`, `< BaseCrawler`)
- 抓取单个小红书帐号：获取笔记列表 → 获取详情 → 保存文章
- 统计新增/跳过/失败数量

**Retryable** (`lib/retryable.rb`)
- 统一重试模块，支持指数退避
- HTTP 状态码感知：5xx/429 可重试，4xx 立即失败
- API 密钥错误（任何 `include CrawlerApiKeyError` 的异常）不重试，立即失败
- 可配置重试次数、重试异常类型

### 添加新的抓取平台（如 Twitter）

得益于 `CrawlOrchestrator` + `BaseCrawler` 的插件式设计，新增平台无需改动调度逻辑：

1. 新增 `Account` 的 STI 子类（如 `TwitterAccount`），实现 `platform_name` 和 `self.crawler_class`（返回下面的 Crawler 类）
2. 新增 `XxxCrawler < BaseCrawler`，实现 `self.crawl_account(account, crawl_task, article_concurrency:, max_pages:)`
3. 如该平台 API 有密钥失效的场景，将对应错误类 `include CrawlerApiKeyError`
4. 完成 — `CrawlJob` / `CrawlOrchestrator` 会自动把该类型帐号纳入同一个并发循环，与其他平台交替抓取

**Accounts::Importer** (`app/services/accounts/importer.rb`)
- 微信帐号导入服务
- 支持 JSON 文本、文件上传、搜索导入

**Rednote::Importer** (`app/services/rednote/importer.rb`)
- 小红书帐号导入服务

**CrawlJob** (`app/jobs/crawl_job.rb`)
- Active Job，负责重试时重置失败帐号、初始化帐号追踪，然后委托 `CrawlOrchestrator` 执行实际抓取
- 不再关心帐号平台类型，也不再按平台顺序调用不同 Crawler

### 控制器

- `AccountsController`：帐号 CRUD、导入（JSON/搜索/小红书）、触发抓取
- `CrawlTasksController`：任务列表/详情、暂停/恢复/标记失败、查看日志和文章
- `DashboardController`：仪表盘首页
- `SessionsController`：登录/登出、magic link、dev_login
- `ProfilesController`：用户密码管理
- `RssController`：RSS feed 输出
- `Admin::UsersController`：用户管理（admin only）
- `Admin::SettingsController`：系统设置（admin only）

### 关注点分离（Concerns）

- `Authentication`：session 认证、cookie 管理
- `Authorization`：admin 权限检查
- `QueryPersistenceConcern`：Ransack 查询参数持久化

### 路由结构

```
# 认证
resource :session + magic_link + dev_login
GET /magic_link/:token -> sessions#magic_link_login

# 业务
resources :accounts (index, show, destroy, import, search_preview, import_json, import_search, import_rednote_json, crawl, toggle_status)
resources :crawl_tasks (index, show, crawl_all, pause, resume, fail, logs, articles)
resource :profile (edit, update, update_password)

# Admin
namespace :admin { resources :users (reset_password, credentials); resource :settings }

# RSS
GET /rss                              # 全局（支持 ?period=today|yesterday|7days|1month）
GET /rss/accounts                     # 帐号列表
GET /rss/accounts/active              # 活跃帐号列表
GET /rss/:fakeid                      # 单帐号

# 系统
GET /up                               # health check
/admin/jobs                           # MissionControl::Jobs (admin only)
```

## 开发指南

### 环境要求

- Ruby 3.3+
- Rails 8.1
- SQLite3

### 初始化

```bash
bundle install
rails db:create db:migrate

# 配置 MiraclePlus OAuth（推荐）
# 编辑加密凭据文件，添加以下内容：
EDITOR="code --wait" rails credentials:edit
# mp_oauth:
#   client_id: your_client_id
#   client_secret: your_client_secret

# 命令行导入帐号
rails import:accounts

# 设置 API Key（rails console）
Option.set('wechat_api_key', 'your-key-here')
Option.set('wechat_api_key_expires_at', 4.days.from_now.iso8601)
Option.set('default_article_concurrency', '10')
Option.set('default_account_concurrency', '3')
Option.set('max_crawl_pages', '1')
```

### 启动服务

```bash
bin/dev          # 开发环境（含 TailwindCSS watch）
rails server     # 或直接启动 Rails
```

### 定时清理日志

```bash
# 清理过期日志（按 Option 中的 crawler_log_retention_days 配置）
rails crawl:cleanup_logs
```

## 使用说明

### 1. 导入帐号

**微信公众号**：
1. `/accounts/import` → 选择 "Paste JSON" / "Upload File" / "Search"
2. 搜索导入：输入关键词 → 预览结果 → 选择帐号 → 导入
3. JSON 导入：粘贴或上传 JSON 文件

**小红书**：
1. `/accounts/import` → 选择小红书导入 Tab
2. 粘贴或上传 JSON 数据

**命令行**：`rails import:accounts`（读取 `wechat_accounts_import_final.json`）

### 2. 配置 API Key

访问 `/admin/settings`：
- **微信公众号 Key**：从 https://down.mptext.top/dashboard/api 获取，每 4 天过期
- **小红书 Key**：从 API 提供商获取

### 3. 手动抓取

- 单帐号：帐号详情页点击 "Crawl Now"
- 全部帐号：任务列表页点击 "Crawl All"
- 所有帐号（不分平台）在同一个抓取任务中并发交替执行，而非按平台分批顺序抓取

### 4. 重试失败帐号

**自动重试**：任务完成时若有帐号失败，系统自动调度重试（最多 5 次，指数退避 5→10→20→40→60 分钟）。

**手动重试**：任务运行中或完成后，如有失败帐号，显示 "重试失败帐号" 按钮：
- 运行中：先暂停 → 重试失败帐号
- 已完成：重新启动任务，只处理失败帐号
- 已完成的帐号不会被重复抓取
- 手动 resume 会重置自动重试计数器

### 5. 订阅 RSS

```
https://your-domain.com/rss                          # 全局（默认最近7天）
https://your-domain.com/rss?period=today              # 今天
https://your-domain.com/rss?period=yesterday          # 昨天
https://your-domain.com/rss?period=7days              # 最近7天
https://your-domain.com/rss?period=1month             # 最近1个月
https://your-domain.com/rss/{fakeid}                  # 单帐号
https://your-domain.com/rss/accounts                  # 帐号列表
https://your-domain.com/rss/accounts/active           # 活跃帐号列表
```

## 并发控制

使用 `async` gem 在 Puma 进程中实现并发，无需额外 background job 系统。

### 双层并发

- **帐号并发**（`account_concurrency`）：同时抓取的帐号数，默认 3
- **文章并发**（`article_concurrency`）：同时下载的文章数，默认 10

### 配置

- **全局默认**：通过 Option 设置
- **任务级别**：CrawlTask 可独立设置
- **手动触发**：使用全局默认值

### Semaphore 机制

```ruby
Async do |task|
  account_semaphore = Async::Semaphore.new(account_concurrency)
  accounts.each do |account|
    account_semaphore.async do
      article_semaphore = Async::Semaphore.new(article_concurrency)
      articles.each { |a| article_semaphore.async { fetch(a) } }
    end
  end
end
```

## 错误处理

### API Key 过期/缺失
- 遇到 API 密钥错误时，**只标记该帐号失败**，不暂停整个任务
- 任务继续运行，**其他平台的帐号不受影响**（如微信密钥失效，小红书仍可继续）
- 同平台的其他帐号仍会尝试（虽然大概率也失败）
- 失败帐号可在任务结束后通过自动重试或手动重试恢复（更新密钥后）

### 限流 (429)
- `Retryable` 模块自动重试，指数退避（2s → 4s → 8s）
- 超过重试次数后该帐号标记为失败，任务继续
- API 密钥错误不重试，立即标记帐号失败（由 `CrawlerApiKeyError` mixin 统一识别）

### 错误阈值
- 累计错误 >= 200（`ERROR_THRESHOLD`）自动终止任务
- 每个帐号独立追踪错误

### 帐号级别重试
- 每个帐号独立状态（pending/running/completed/failed）
- 已完成帐号不会被重复抓取
- resume 时自动重置 failed 帐号为 pending

## 实时更新

使用 Turbo Streams 广播任务进度：
- `CrawlTask#broadcast_updates` → 广播到 `[task, :show]` 频道
- 任务详情页实时更新进度、日志、状态
- 注意：曾因过度广播导致 62GB cable 数据库问题，已修复

## 目录结构

```
mp-crawler/
├── app/
│   ├── controllers/
│   │   ├── accounts_controller.rb
│   │   ├── crawl_tasks_controller.rb
│   │   ├── dashboard_controller.rb
│   │   ├── profiles_controller.rb
│   │   ├── rss_controller.rb
│   │   ├── sessions_controller.rb
│   │   ├── concerns/ (authentication, authorization, query_persistence)
│   │   └── admin/ (settings, users)
│   ├── models/
│   │   ├── account.rb (STI base)
│   │   ├── wechat_account.rb
│   │   ├── rednote_account.rb
│   │   ├── article.rb
│   │   ├── crawl_task.rb
│   │   ├── crawl_task_account.rb
│   │   ├── crawl_log.rb
│   │   ├── option.rb
│   │   ├── user.rb
│   │   └── session.rb
│   ├── services/
│   │   ├── accounts/importer.rb
│   │   └── rednote/importer.rb
│   ├── jobs/
│   │   └── crawl_job.rb
│   ├── mailers/
│   │   ├── admin_mailer.rb
│   │   └── application_mailer.rb
│   └── views/
│       ├── accounts/ (index, show, import, import_preview)
│       ├── crawl_tasks/ (index, show, logs, articles, partials)
│       ├── admin/ (settings, users)
│       ├── rss/ (index, show, accounts, active_accounts)
│       └── sessions/ (new)
├── lib/
│   ├── crawl_orchestrator.rb  (跨平台统一调度，交替抓取所有帐号)
│   ├── base_crawler.rb        (平台 Crawler 基类/接口)
│   ├── crawler_api_key_error.rb (API 密钥错误通用 mixin)
│   ├── wechat_api_client.rb
│   ├── wechat_crawler.rb       (< BaseCrawler)
│   ├── rednote_api_client.rb
│   ├── rednote_crawler.rb      (< BaseCrawler)
│   └── retryable.rb
├── db/migrate/
└── config/routes.rb
```

## 限制与注意事项

### API 限制
- 微信：每请求最多 20 篇文章，需翻页
- 小红书：分页获取，每页间隔 1 秒
- 两个 API 均可能有频率限制

### API Key 管理
- 微信 Key 每 4 天过期，需人工登录更新
- 小红书 Key 无过期机制
- 过期后任务自动暂停

### 并发控制
- 建议帐号并发：3-5
- 建议文章并发：5-20
- 过高可能触发限流

### 错误阈值
- 累计 200 个错误自动终止任务
- 防止无限重试导致资源浪费

### 自动重试
- 任务完成时若有帐号抓取失败，自动调度重试（而非直接标记为完成）
- 最多重试 5 次（`CrawlTask::MAX_RETRIES`）
- 指数退避：5 → 10 → 20 → 40 → 60 分钟（上限 60 分钟）
- 重试时自动重置失败帐号为 pending，已完成帐号不会重复抓取
- 超过最大重试次数后，任务标记为失败并记录原因
- 手动 resume 会重置重试计数器

### ActionCable 注意事项
- 曾因过度广播导致 62GB cable 数据库
- 现仅在 `increment_progress!` 和 `increment_error_count!` 时广播
- 广播目标限定为任务详情页 `[task, :show]`

## 后续计划

- [ ] 高校专业分布数据集成
- [ ] 活动分析看板
- [ ] 文章全文搜索
- [ ] 批量导出功能
- [ ] API 接口（供第三方调用）
- [ ] 邮件通知（抓取完成/失败）
- [ ] 定时调度
