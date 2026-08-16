# MP-Crawler

微信公众号、小红书和 Twitter 文章爬虫 & RSS 订阅服务

## 项目简介

MP-Crawler 是一个基于 Ruby on Rails 的应用，用于自动抓取微信公众号、小红书和 Twitter 文章，并提供 RSS 订阅服务。主要面向高校帐号，支持多平台、进度保存、断点续传、并发控制等功能。

## 技术栈

- **Framework**: Ruby on Rails 8.1
- **Database**: PostgreSQL
- **CSS**: TailwindCSS with CSS custom properties
- **Concurrency**: Async gem with Semaphore (runs in Puma process)
- **Frontend**: Stimulus.js, Turbo (Turbo Streams for real-time UI updates)
- **HTTP Client**: Faraday with faraday-retry
- **Pagination**: Kaminari
- **Search**: Ransack
- **Authentication**: has_secure_password + magic link login + MiraclePlus OAuth

## 核心功能

### 1. 多平台帐号管理
- 支持微信公众号（WechatAccount）、小红书（RednoteAccount）和 Twitter（TwitterAccount）三种平台
- 使用 STI（Single Table Inheritance）模型：`Account` 基类，`WechatAccount` / `RednoteAccount` / `TwitterAccount` 子类
- 从 JSON 文件导入帐号列表（支持粘贴或上传）
- 从 API 搜索帐号并导入（微信公众号搜索、小红书搜索、Twitter 用户名查找、微信文章 URL 解析）
- 网页界面导入：支持 JSON 文本、文件上传、搜索导入、按 URL/ID 导入
- 命令行导入：`rails import:accounts`
- 查看帐号详情和文章列表（支持分页和 Ransack 搜索）
- 设置帐号状态（active/inactive）、批量启用/停用/删除
- 按活跃度分层查看与调度（active/slow/dormant/dead/never/uncrawled）
- 手动触发抓取

### 2. 文章抓取
- **微信公众号**：支持多种 API 提供方（`Option.wechat_api_provider` 切换）——`mp_native`（默认，扫码登录 `mp.weixin.qq.com`）/ `dajiala` / `profile_ext`（mitmproxy 凭证）/ `weread`（微信读书转发）
- **文章正文下载**：由独立每日任务 `WechatContentDownloadJob` 下载所有缺失正文的微信文章（正文直接从 `mp.weixin.qq.com` 抓取，严格限流，最新文章优先）；缺失正文的文章也可在界面重新下载
- **小红书**：使用第三方 API（`api.yddm.com`），用户搜索走 TikHub API（`api.tikhub.io`）
- **Twitter**：使用 twitter-api-client Python 库（cookie 认证）
- 异步并发抓取（可配置帐号并发数和文章并发数）
- 支持暂停和恢复
- 自动保存进度，支持断点续传
- 重复文章自动跳过（URL 唯一索引）
- 统一重试机制（`Retryable` 模块，指数退避）
- 错误阈值保护（累计错误 >= 50，按平台统计，超出后仅终止该平台）

### 3. 抓取任务管理
- `CrawlTask`：抓取任务，支持 pending/running/paused/completed/failed 状态
- `CrawlTaskAccount`：按帐号追踪抓取状态，支持独立重试失败帐号
- `CrawlLog`：结构化日志记录
- JS 轮询实时更新任务进度到 UI（指数退避，任务完成自动停止）
- 按帐号并发和文章并发分别控制

### 4. 抓取日志
- `CrawlLog`：结构化日志记录（debug/info/warn/error）
- 仅在 `verbose_mode` 开启时写入日志
- 支持日志清理（按保留天数配置）

### 5. 标签系统
- `Tag`：标签模型，支持名称、颜色、描述、排序位置
- `TagAccount`：帐号与标签的多对多关联（counter_cache 自动计数）
- `UserTag`：用户关注标签（followed tags）
- 帐号批量打标签/移除标签（Bulk Actions）
- 标签自动补全（tag_suggestions API）
- 按标签筛选帐号列表（Ransack scope: `with_tag_id`）
- 仪表盘按用户关注标签过滤最新文章
- 用户 Profile 页面管理关注的标签
- Admin 标签管理：编辑名称/颜色/描述/排序、删除标签、刷新计数
- 按标签和用户生成 RSS feed（`/rss/tag/:tag_id`、`/rss/user/:token`）

### 6. RSS 订阅
- 全局 RSS feed：`/rss`（支持按时间段过滤：today/yesterday/7days/1month）
- 单帐号 RSS feed：`/rss/{fakeid}`
- 帐号列表 RSS：`/rss/accounts`、`/rss/accounts/active`
- 自动包含最近 50 篇文章

### 7. 用户认证与权限
- 基于 `has_secure_password` 的密码认证
- **MiraclePlus OAuth 登录**（推荐）
- Magic Link 邮箱登录（免密码）
- 开发环境 dev_login 快捷登录
- 角色系统：admin / user（首个 OAuth 用户自动成为 admin）
- 邮箱验证机制
- `AdminMailer`：邀请邮件、登录链接邮件、新用户凭据邮件

### 8. API Key 管理
- **微信公众号**（`mp_native`）：通过 QR 码扫码登录（在 `/admin/settings` 页面），Cookie/Token 有效期约 2 小时
- **微信读书（WeRead）**：转发服务帐号池（支持多账号、QR 扫码登录、每日黑名单），在 `/admin/settings` 统一管理
- **大家拉（Dajiala）**：`dajiala_api_key`
- **Profile Ext**：mitmproxy 抓取的凭证（`profile_ext_credentials`，约 25 分钟过期）
- **小红书**：`rednote_api_key`，无过期机制
- **TikHub**：`tikhub_api_key`（用于小红书用户搜索）
- **Twitter**：`twitter_ct0` + `twitter_auth_token` cookie
- 在 `/admin/settings` 页面统一管理，`ValidateApiKeysJob` 定期校验并向管理员发送失效通知

### 9. 帐号分组
- `Group` / `GroupAccount`：用户可创建分组（`ref_key` 唯一），将帐号归入不同分组
- 提供 REST API（`/api/v1/groups`）供第三方读取分组、文章和帐号列表

### 10. REST API
- `/api/v1/groups`：分组的 CRUD
- `/api/v1/articles`：文章列表
- `/api/v1/accounts`：帐号列表
- 基于用户 `ApiKey`（`has_secure_token`，SHA256 摘要存储）鉴权

## 架构设计

### 数据模型

```
Account (帐号 - STI 基类)
├── WechatAccount (微信公众号)
├── RednoteAccount (小红书)
├── TwitterAccount (Twitter)
├── has_many :articles
├── has_many :groups, through: :group_accounts
├── enum status: { active: 0, inactive: 1 }
├── 活跃度字段: activity_score / articles_last_7_days / articles_last_30_days / total_articles / last_published_at
├── 调度字段: last_crawled_at / next_crawl_at（按活跃度分层计算下次抓取时间）
├── CRAWL_INTERVALS: active 1 天 / slow 3 天 / dormant 7 天 / dead 21 天 / never 30 天
├── activity_level: 活跃度分层实例方法（uncrawled/never/active/slow/dormant/dead），by_activity_level scope 与之镜像
├── self.crawler_class (子类各自返回对应的 Crawler，供 CrawlOrchestrator 分发)
└── scope :active, :needs_crawling, :recently_crawled, :due_for_crawl, :uncrawled, :never_published

Article (文章)
├── belongs_to :account
├── belongs_to :crawl_task (optional)
├── validates :url, uniqueness: true
├── raw_data (json - 原始 API 响应数据，微信为文章列表项，小红书为笔记详情完整响应)
├── content_html / content_markdown (正文，微信文章正文下载失败时为 nil，可重新下载)
├── download_content! (从原文 URL 重新下载微信文章正文)
└── scope :recent, :today, :yesterday, :last_7_days, :last_month

CrawlTask (抓取任务)
├── has_many :crawl_logs
├── has_many :crawl_task_accounts
├── has_many :articles
├── enum status: { pending: 0, running: 1, paused: 2, completed: 3, failed: 4 }
├── ERROR_THRESHOLD = 50（支持按平台统计 platform_error_counts）
└── 失败帐号不再自动重试，完成后标记为 failed，由用户手动重试

CrawlTaskAccount (帐号抓取状态)
├── belongs_to :crawl_task
├── belongs_to :account
├── enum status: { pending: 0, running: 1, completed: 2, failed: 3 }
└── scope :incomplete

CrawlLog (抓取日志)
├── belongs_to :loggable (polymorphic，可挂 CrawlTask 或 WechatContentDownloadTask)
├── LEVELS: debug, info, warn, error
└── 仅在 verbose_mode 开启时写入

WechatContentDownloadTask (微信正文下载任务)
├── has_many :crawl_logs, as: :loggable
├── enum status: { running / completed / failed / stale }
└── job_id + heartbeat_at（每日 Job 防重叠，心跳过期接管）

Option (系统配置 - key-value 存储)
- wechat_mp_cookie / wechat_mp_token / wechat_mp_expires_at (微信 mp_native 扫码登录)
- wechat_api_provider (微信 API 提供方：mp_native / dajiala / profile_ext / weread)
- dajiala_api_key / tikhub_api_key / rednote_api_key
- profile_ext_credentials (mitmproxy 凭证，约 25 分钟过期)
- weread_platform_url / weread_accounts / weread_blocked_accounts (微信读书转发服务)
- twitter_ct0 / twitter_auth_token (Twitter cookie 认证)
- default_article_concurrency / default_account_concurrency
- max_crawl_pages / crawler_verbose_mode
- daily_crawl_budget (定时抓取单次最多处理的帐号数，默认 200)
- wechat_download_rate_limit / wechat_download_rate_window (微信正文下载限流，默认 5 次/60 秒)
- crawl_wechat_enabled / crawl_rednote_enabled / crawl_twitter_enabled (各平台抓取开关)

Tag (标签)
├── has_many :tag_accounts (counter_cache: tag_accounts_count)
├── has_many :accounts, through: :tag_accounts
├── has_many :user_tags
├── has_many :followers, through: :user_tags, source: :user
├── validates :name_normalized, uniqueness: true
└── scope :ordered (position ASC, name ASC)

TagAccount (帐号-标签关联)
├── belongs_to :tag
├── belongs_to :account
└── validates :account_id, uniqueness: { scope: :tag_id }

UserTag (用户关注标签)
├── belongs_to :user
├── belongs_to :tag
└── validates :tag_id, uniqueness: { scope: :user_id }

User (用户)
├── enum role: { user: 0, admin: 1 }
├── has_many :sessions
├── has_many :user_tags
├── has_many :followed_tags, through: :user_tags, source: :tag
├── has_many :api_keys
├── has_secure_password
└── magic link / email confirmation / password reset tokens

Group (分组)
├── belongs_to :user
├── has_many :group_accounts
├── has_many :accounts, through: :group_accounts
└── validates :ref_key, uniqueness: { scope: :user_id }

GroupAccount (分组-帐号关联)
├── belongs_to :group
├── belongs_to :account
└── validates :account_id, uniqueness: { scope: :group_id }

ApiKey (用户 API Key)
├── belongs_to :user
├── has_secure_token :token（SHA256 摘要存储）
└── scope :active
```

### 核心服务

**CrawlOrchestrator** (`lib/crawl_orchestrator.rb`)
- 统一的抓取调度器：每个平台运行在独立的 `Async::Semaphore` 任务中**交替抓取所有平台**的帐号（微信、小红书、Twitter），而非先抓完一个平台再抓下一个
- 按 `account.class.crawler_class` 把每个帐号分发给对应平台的 Crawler
- 负责暂停/恢复/错误阈值终止等任务级别的通用逻辑
- 按平台统计错误（`platform_error_counts`），某平台累计错误超阈值时只跳过该平台剩余帐号，其他平台不受影响
- 各平台可通过 `Option.crawl_*_enabled` 开关独立禁用
- 只负责抓取文章列表；正文下载由独立每日任务 `WechatContentDownloadJob` 处理
- 捕获 `CrawlerApiKeyError`（见下）并将任务置为 paused，不影响其他帐号继续抓取
- API 速率限制由各平台 API Client 的 Faraday 中间件处理（如 `WechatCrawler.download_connection` 的 `RateLimiterMiddleware`），调度层无需平台特定的 sleep

**BaseCrawler** (`lib/base_crawler.rb`)
- 所有平台 Crawler 的基类，只定义一个接口：`self.crawl_account(account, crawl_task, article_concurrency:, max_pages:)`
- 平台 Crawler 只需实现「如何抓取单个帐号」，不再关心跨帐号的并发调度（由 `CrawlOrchestrator` 统一负责）

**CrawlerApiKeyError** (`lib/crawler_api_key_error.rb`)
- 各平台 API 密钥错误的通用 mixin（`include CrawlerApiKeyError`）
- `Retryable` 和 `CrawlOrchestrator` 通过它统一识别"密钥缺失/过期"类错误并立即失败/暂停任务，无需逐个平台硬编码错误类

**WechatMpNativeApiClient** (`lib/wechat_mp_native_api_client.rb`)
- 直接访问微信公众号平台（`mp.weixin.qq.com`），无需第三方 API
- 认证方式：QR 码扫码登录，获取 Cookie + Token（有效期约 2 小时）
- 主要接口：`search_account`、`get_articles`、`download_content`
- 自定义错误类：`ApiError`、`SessionExpiredError`（包含 `CrawlerApiKeyError`）、`LoginRequiredError`（包含 `CrawlerApiKeyError`）、`RateLimitError`

**DajialaApiClient** (`lib/dajiala_api_client.rb`)
- 备选微信文章 API（`dajiala.com`），通过 `Option.wechat_api_provider = "dajiala"` 启用
- 提供与 `WechatMpNativeApiClient` 相同的接口（`get_articles` / `validate_key`）
- 自定义错误类：`ApiError`、`ApiKeyMissingError`（包含 `CrawlerApiKeyError`）、`ApiRateLimitError`

**ProfileExtApiClient** (`lib/profile_ext_api_client.rb`)
- 备选微信文章 API，使用 mitmproxy 抓取的凭证（`Option.profile_ext_credentials`，约 25 分钟过期）
- 提供与 `WechatMpNativeApiClient` 相同的接口（`get_articles` / `download_content` / `validate_key`）
- 自定义错误类：`ApiError`、`CredentialExpiredError`（包含 `CrawlerApiKeyError`）、`CredentialMissingError`（包含 `CrawlerApiKeyError`）

**WereadApiClient** (`lib/weread_api_client.rb`)
- 通过微信读书（WeRead）转发服务获取公众号文章列表，通过 `Option.wechat_api_provider = "weread"` 启用
- 多账号池（`Option.weread_accounts`）随机负载均衡 + 每日黑名单（429 限流的账号当天不再使用）
- 文章正文仍由 `WechatCrawler.download_content` 统一处理（直接访问 `mp.weixin.qq.com`）
- 自定义错误类：`ApiError`、`WeReadAccountExpiredError`（包含 `CrawlerApiKeyError`）、`WeReadRateLimitError`、`WeReadBadRequestError`、`NoAvailableAccountError`

**WechatCrawler** (`lib/wechat_crawler.rb`, `< BaseCrawler`)
- 抓取单个微信公众号：分页获取文章列表并落库（只存元数据，不下载正文）
- 按 `Option.wechat_api_provider` 路由到对应 API Client：`mp_native` / `dajiala` / `profile_ext` / `weread`
- 正文下载由 `download_article_contents` 完成（从 `mp.weixin.qq.com` 直接抓取，`RateLimiter` 严格限流，默认 5 次/60 秒），供独立每日任务 `WechatContentDownloadJob` 批量调用
- 使用 `Retryable` 模块处理重试；微信读书类错误（`NoAvailableAccountError` 等）会中断微信平台剩余帐号

**RednoteApiClient** (`lib/rednote_api_client.rb`)
- 封装小红书 API（`api.yddm.com`）
- 认证方式：`X-API-Key` header
- 主要接口：`get_user_notes`、`get_note_detail`
- 自定义错误类：`ApiError`、`ApiKeyMissingError`（包含 `CrawlerApiKeyError`）、`ApiRateLimitError`

**TikHubApiClient** (`lib/tik_hub_api_client.rb`)
- 封装 TikHub API（`api.tikhub.io`），用于小红书用户搜索
- 认证方式：`Authorization: Bearer` header（`Option.tikhub_api_key`）
- 主要接口：`search_users`
- 自定义错误类：`ApiError`、`ApiKeyMissingError`（包含 `CrawlerApiKeyError`）、`ApiRateLimitError`

**RednoteCrawler** (`lib/rednote_crawler.rb`, `< BaseCrawler`)
- 抓取单个小红书帐号：获取笔记列表 → 获取详情 → 保存文章
- 统计新增/跳过/失败数量

**TwitterApiClient** (`lib/twitter_api_client.rb`)
- 通过 Python 脚本 (`bin/twitter_fetch.py`) 调用 twitter-api-client 库
- 认证方式：Cookie 认证（`twitter_ct0` + `twitter_auth_token`）
- 主要接口：`get_user_tweets`、`lookup_user`、`validate_key`
- 自定义错误类：`ApiError`、`ApiKeyMissingError`（包含 `CrawlerApiKeyError`）、`ApiRateLimitError`

**TwitterCrawler** (`lib/twitter_crawler.rb`, `< BaseCrawler`)
- 抓取单个 Twitter 帐号：获取推文列表 → 保存为文章
- 解析推文文本、媒体、互动数据（点赞/转推/回复/浏览量）
- 使用推文 URL 作为唯一标识避免重复

**RateLimiter** (`lib/rate_limiter.rb`)
- 通用滑动窗口速率限制器
- 线程安全（Mutex）+ 协程安全（Async 兼容 — sleep 会让出 reactor）
- 按实例隔离，不同端点可设不同限制
- 主要用于限制微信正文下载（`Option.wechat_download_rate_limit`，默认 5 次/60 秒）及各平台文章列表请求

**RateLimiterMiddleware** (`lib/rate_limiter_middleware.rb`)
- Faraday 中间件，在每次 HTTP 请求前调用 `rate_limiter.wait`
- 注册为 `:rate_limiter`，可与 retry 等中间件组合使用
- 仅应用于需要限流的连接（如 `WechatCrawler.download_connection`、`WereadApiClient.platform_connection` 等）

**Retryable** (`lib/retryable.rb`)
- 应用层重试模块，专注于 API 语义级错误处理
- 传输层重试（超时、连接失败、HTTP 5xx）由 Faraday retry 中间件处理
- `Retryable` 负责：应用层错误重试（如响应体中的频率限制）、API 密钥错误短路（`CrawlerApiKeyError` 立即失败）、抓取任务错误追踪和日志记录（`crawl_task.log`）
- 指数退避（2s → 4s → 8s）；HTTP 客户端错误（4xx）不重试

**AccountResolver** (`app/services/account_resolver.rb`)
- 统一的多平台帐号解析/搜索服务
- 微信：关键字搜索（`WechatMpNativeApiClient`）、文章 URL 解析（`WereadApiClient.get_mp_info`）
- 小红书：关键字搜索（`TikHubApiClient`）、按 ID 查找（`RednoteApiClient`）
- Twitter：按用户名查找（`TwitterApiClient`）
- 搜索结果先查数据库，命中则复用，否则创建新帐号

**ResponseCacheMiddleware** (`lib/response_cache_middleware.rb`)
- Faraday 响应缓存中间件（`Rails.cache`），避免短时间内重复请求同一 URL

**MarkdownCharsetMiddleware** (`lib/markdown_charset_middleware.rb`)
- Faraday 中间件，修正正文响应编码为 UTF-8

### 添加新的抓取平台

得益于 `CrawlOrchestrator` + `BaseCrawler` 的插件式设计，新增平台无需改动调度逻辑：

1. 新增 `Account` 的 STI 子类（如 `TwitterAccount`），实现 `platform_name` 和 `self.crawler_class`（返回下面的 Crawler 类）
2. 新增 `XxxCrawler < BaseCrawler`，实现 `self.crawl_account(account, crawl_task, article_concurrency:, max_pages:)`
3. 如该平台 API 有密钥失效的场景，将对应错误类 `include CrawlerApiKeyError`
4. 如该平台 API 有频率限制，在 API Client 中使用 `RateLimiter` + `RateLimiterMiddleware`（参考 `WechatMpNativeApiClient` / `WereadApiClient`）
5. 完成 — `CrawlJob` / `CrawlOrchestrator` 会自动把该类型帐号纳入同一个并发循环，与其他平台交替抓取

### 添加新的导入平台

每个平台的导入功能遵循统一的模式，确保可扩展性和用户体验一致性：

**架构原则**：
- **独立页面**：每个平台有独立的导入页面（`/accounts/import/{platform}`），避免表单状态丢失
- **错误隔离**：某个平台导入失败不影响其他平台，错误信息截断避免 cookie overflow
- **统一模式**：所有平台遵循相同的路由、控制器和视图结构

**新增平台步骤**：

1. **路由**（`config/routes.rb`）：
```ruby
# 在 accounts collection 中添加
get  "import/{platform}", to: "accounts#import_{platform}_page", as: :import_{platform}_page
post :import_{platform}
post :import_{platform}_file
# 如支持搜索导入
get  :import_{platform}_search
```

2. **控制器**（`app/controllers/accounts_controller.rb`）：
```ruby
def import_{platform}_page
  # 渲染导入页面
end

def import_{platform}
  # 处理导入逻辑
  # 错误时 redirect_to import_{platform}_page_accounts_path
  # 使用 truncate_error() 避免 cookie overflow
end

def import_{platform}_file
  # 处理文件上传导入
end
```

3. **视图**：
- `app/views/accounts/import_{platform}_page.html.erb` - 导入页面
- `app/views/accounts/import_preview_{platform}.html.erb` - 搜索结果预览（如支持搜索）

4. **服务**（`app/services/{platform}/importer.rb`）：
```ruby
module {Platform}::Importer
  def self.import_text(text)
  def self.import_file(file)
  def self.import_search_rows(rows)
end
```

5. **更新主导入页面**（`app/views/accounts/import.html.erb`）：
- 添加新平台的卡片链接

**错误处理规范**：
- 使用 `truncate_error(message)` 方法截断错误信息（最大 200 字符）
- 所有错误重定向回对应平台的导入页面，而非主导入页面
- 避免直接使用 `flash[:error] = e.message`，防止 cookie overflow

**Accounts::Importer** (`app/services/accounts/importer.rb`)
- 微信帐号导入服务
- 支持 JSON 文本、文件上传、搜索导入、文章 URL 解析导入

**Rednote::Importer** (`app/services/rednote/importer.rb`)
- 小红书帐号导入服务

**Twitter::Importer** (`app/services/twitter/importer.rb`)
- Twitter 帐号导入服务
- 支持 JSON 文本导入和用户名查找导入

**CrawlJob** (`app/jobs/crawl_job.rb`)
- Active Job，初始化帐号追踪，然后委托 `CrawlOrchestrator` 执行实际抓取
- 不再关心帐号平台类型，也不再按平台顺序调用不同 Crawler
- 两种调用方式：
  - 传入 `crawl_task_id`：执行指定任务（手动抓取 / 失败重试）
  - 不传参数（定时任务）：仅抓取「到期」帐号（`Account.due_for_crawl_ids`，受 `daily_crawl_budget` 上限约束）

**CleanupOldTasksJob** (`app/jobs/cleanup_old_tasks_job.rb`)
- 定时清理一周前的终态抓取任务（completed/failed）

**RefreshActivityCountersJob** (`app/jobs/refresh_activity_counters_job.rb`)
- 每周刷新所有帐号的活跃度计数（`refresh_activity_counters!`）

**ValidateApiKeysJob** (`app/jobs/validate_api_keys_job.rb`)
- 定期校验微信 / 小红书 / Twitter 的 API Key 有效性，失效时通过 `AdminMailer` 通知管理员（24 小时内去重）

**WechatContentDownloadJob** (`app/jobs/wechat_content_download_job.rb`)
- 每日下载所有缺失正文（`content_html IS NULL`）的微信文章，最新文章优先
- 通过 `WechatContentDownloadTask` 的 `job_id` + `heartbeat_at` 防重叠：上一个 Job 仍在跑则跳过，心跳过期则接管

### 控制器

- `AccountsController`：帐号 CRUD、导入（JSON/搜索/按 URL/按 ID/小红书/Twitter）、触发抓取、批量操作
- `CrawlTasksController`：任务列表/详情、暂停/恢复/标记失败、查看日志和文章、抓取到期帐号
- `WechatContentDownloadTasksController`：正文下载任务列表/详情、手动触发、查看日志
- `ArticlesController`：文章详情、重新下载正文（`download_content`）
- `DashboardController`：仪表盘首页
- `SessionsController`：登录/登出、magic link、dev_login、OAuth 登录
- `ProfilesController`：用户密码管理、关注标签、API Key 管理
- `RssController`：RSS feed 输出
- `Admin::UsersController`：用户管理（admin only）、管理用户关注标签
- `Admin::TagsController`：标签管理（admin only）、编辑/删除/刷新计数
- `Admin::SettingsController`：系统设置（admin only），含各平台 API Key 校验、微信/微信读书扫码登录
- `Admin::AnalyticsController`：活跃度分析看板、批量停用停更帐号（admin only）
- `Api::V1::GroupsController` / `AccountsController` / `ArticlesController`：REST API（基于 ApiKey 鉴权）

### 关注点分离（Concerns）

- `Authentication`：session 认证、cookie 管理
- `Authorization`：admin 权限检查
- `QueryPersistenceConcern`：Ransack 查询参数持久化

### 路由结构

```
# 认证
resource :session + magic_link + dev_login + OAuth (GET /auth/:provider, /oauth/:provider/callback)
GET /magic_link/:token -> sessions#magic_link_login

# 文章
resources :articles (show) + post :download_content (重新下载微信正文)

# 业务
resources :accounts (index, show, update, destroy) do
  collection do
    # 标签操作
    post :bulk_tag / :bulk_untag / :bulk_enable / :bulk_disable / :bulk_destroy / :bulk_crawl
    get  :tag_suggestions
    post :toggle_tag_follow

    # 导入主页
    get :import

    # 微信公众号导入
    get  "import/wechat", to: :import_wechat_page, as: :import_wechat_page
    get  :import_wechat_search
    post :import_wechat
    post :import_wechat_file
    post :import_wechat_by_url        # 通过文章 URL 解析并导入

    # 小红书导入
    get  "import/rednote", to: :import_rednote_page, as: :import_rednote_page
    get  :import_rednote_search
    post :import_rednote
    post :import_rednote_file
    post :import_rednote_by_id        # 通过用户 ID 导入

    # Twitter 导入
    get  "import/twitter", to: :import_twitter_page, as: :import_twitter_page
    get  :import_twitter_search
    post :import_twitter
    post :import_twitter_file
  end
  member do
    post :crawl
    post :toggle_status
    post :resolve_weread_mp_id
  end
end
resources :crawl_tasks (index, show, destroy) do
  collection { post :crawl_due }       # 抓取到期帐号
  member { post :pause / :resume / :fail; get :logs / :articles / :poll }
end
resources :wechat_content_download_tasks (index, show, destroy) do
  collection { post :run }             # 手动触发正文下载
  member { get :logs / :poll }
end
resource :profile (edit, update, update_password, update_followed_tags, create_api_key, revoke_api_key)

# Admin
namespace :admin {
  resources :users (reset_password, update_followed_tags, credentials)
  resources :tags (edit, update, destroy, refresh_counts)
  resource :settings (validate_*_key, wechat_mp QR 登录, weread QR 登录/帐号管理)
  resource :analytics (bulk_disable_dormant)
}

# API (REST, ApiKey 鉴权)
namespace :api v1 {
  resources :groups (index, show, create, update, destroy)
  resources :articles (index)
  resources :accounts (index)
}

# RSS
GET /rss                              # 全局（支持 ?period=today|yesterday|7days|1month）
GET /rss/accounts                     # 帐号列表
GET /rss/accounts/active              # 活跃帐号列表
GET /rss/tag/:tag_id                  # 按标签过滤
GET /rss/user/:token                  # 按用户关注标签过滤
GET /rss/:fakeid                      # 单帐号

# 系统
GET /up                               # health check
/admin/jobs                           # MissionControl::Jobs (admin only)
```

## 开发指南

### 环境要求

- Ruby 3.3+
- Rails 8.1
- PostgreSQL

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

# 设置默认并发数和页数（rails console）
Option.set('default_article_concurrency', '10')
Option.set('default_account_concurrency', '3')
Option.set('max_crawl_pages', '1')
```

### 启动服务

```bash
bin/dev          # 开发环境（含 TailwindCSS watch）
rails server     # 或直接启动 Rails
```

### 命令行任务

```bash
# 清理过期日志（按 Option 中的 crawler_log_retention_days 配置）
rails crawl:cleanup_logs

# 刷新所有帐号的活跃度计数
rails crawl:refresh_activity_counters

# 检测停更帐号（可加 DAYS 天数，DISABLE=true 时自动停用）
rails crawl:detect_dormant[90,false]

# 微信读书（WeRead）转发帐号管理
rails weread:login                # 扫码登录新增转发帐号
rails weread:accounts_list        # 列出所有转发帐号
rails weread:add_account          # 手动添加 (VID=xxx TOKEN=xxx NAME=xxx)
rails weread:remove_account       # 移除 (VID=xxx)
rails weread:enable_account       # 启用 (VID=xxx)
rails weread:disable_account      # 禁用 (VID=xxx)
rails weread:lookup_mp            # 通过文章 URL 查询公众号信息 (URL=xxx)
rails weread:clear_blocked        # 清除当日黑名单
rails weread:status               # 显示 WeRead 配置状态
```

## 使用说明

### 1. 导入帐号

**微信公众号**：
1. `/accounts/import` → 选择 "Paste JSON" / "Upload File" / "Search" / "By URL"
2. 搜索导入：输入关键词 → 预览结果 → 选择帐号 → 导入
3. JSON 导入：粘贴或上传 JSON 文件
4. URL 导入：粘贴公众号文章链接 → 通过微信读书转发服务解析公众号信息并导入

**小红书**：
1. `/accounts/import` → 选择小红书导入 Tab
2. 粘贴或上传 JSON 数据
3. 按 ID 导入：输入小红书用户 ID 查找并导入（搜索走 TikHub API）

**Twitter**：
1. `/accounts/import` → 选择 Twitter 导入 Tab
2. JSON 导入：粘贴包含 `screen_name` 和 `user_id` 的 JSON 数据
3. 用户名查找：输入 Twitter 用户名（不含 @）→ 查找并导入

**命令行**：`rails import:accounts`（读取 `wechat_accounts_import_final.json`）

### 2. 配置 API Key

访问 `/admin/settings`：
- **微信公众号（mp_native）**：点击"获取登录二维码"，使用微信扫描二维码登录（有效期约 2 小时）
- **微信 API 提供方**：通过 `wechat_api_provider` 在 `mp_native` / `dajiala` / `profile_ext` / `weread` 之间切换
- **微信读书（WeRead）**：扫码登录转发服务，可管理多个转发帐号（启用/禁用/移除）
- **大家拉（Dajiala）Key**：从 API 提供商获取
- **小红书 Key**：从 API 提供商获取
- **TikHub Key**：用于小红书用户搜索
- **Twitter Cookies**：需要 `ct0` 和 `auth_token` 两个 cookie（从浏览器登录 Twitter 后的 Cookie 中获取）

### 3. 手动抓取

- 单帐号：帐号详情页点击 "立即抓取"
- 到期帐号：任务列表页点击 "抓取到期帐号"（仅抓取 `next_crawl_at` 已到期的活跃帐号）
- 所有帐号（不分平台）在同一个抓取任务中并发交替执行，而非按平台分批顺序抓取
- 抓取只负责文章列表；正文下载由每日任务 `WechatContentDownloadJob` 独立处理

### 4. 重试失败帐号

**手动重试**：任务运行中或完成后，如有失败帐号，显示 "重试失败帐号" 按钮：
- 运行中：先暂停 → 重试失败帐号
- 已完成：重新启动任务，只处理失败帐号
- 已完成的帐号不会被重复抓取

**重新下载正文**：文章详情页提供"重新下载"按钮，可对正文缺失（上次下载失败）的微信文章单独重新抓取正文。

### 5. 订阅 RSS

```
https://your-domain.com/rss                          # 全局（默认最近7天）
https://your-domain.com/rss?period=today              # 今天
https://your-domain.com/rss?period=yesterday          # 昨天
https://your-domain.com/rss?period=7days              # 最近7天
https://your-domain.com/rss?period=1month             # 最近1个月
https://your-domain.com/rss/{fakeid}                  # 单帐号
https://your-domain.com/rss/tag/{tag_id}              # 按标签过滤
https://your-domain.com/rss/user/{token}              # 按用户关注标签过滤
https://your-domain.com/rss/accounts                  # 帐号列表
https://your-domain.com/rss/accounts/active           # 活跃帐号列表
```

## 抓取调度

按帐号活跃度分层调度：每个帐号抓取完成后，根据其发布活跃度计算下次抓取时间（`next_crawl_at`），避免对停更帐号做无意义的高频抓取，也避免一次性抓取全部帐号触发反爬限制。

### 活跃度分层与抓取间隔

| 活跃度分层 | 判定条件 | 抓取间隔 |
| --- | --- | --- |
| active（活跃） | 最近 7 天内发布 | 1 天 |
| slow（减速） | 最近 30 天内发布 | 3 天 |
| dormant（停更） | 最近 90 天内发布 | 7 天 |
| dead（失活） | 超过 90 天未发布 | 21 天 |
| never（从未发布） | 已抓取但无文章 | 30 天 |

从未抓取的帐号 `next_crawl_at` 为 NULL，视为「立即到期」。

### 到期帐号的选取

- `Account.due_for_crawl`：活跃且 `next_crawl_at` 已到期的帐号
- `Account.due_for_crawl_ids(limit:)`：按优先级排序并限量返回 —— 从未抓取优先 → 活跃度最高优先 → 逾期最久优先

### 定时任务

`config/recurring.yml` 每天定时触发 `CrawlJob`（不传 `crawl_task_id`），只抓取到期帐号，单次数量受 `daily_crawl_budget` 上限约束（默认 200），超出部分顺延到下次。此外每天定时触发 `WechatContentDownloadJob` 下载缺失正文的微信文章。

### 手动触发

任务列表页「抓取到期帐号」按钮复用同一逻辑，同样只抓取到期帐号。

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
- 微信读书类错误（`NoAvailableAccountError` / `WeReadAccountExpiredError` / `WeReadBadRequestError`）会通过 `fail_platform!` 中断微信平台剩余帐号，其他平台不受影响
- 失败帐号可在任务结束后通过手动重试恢复（更新密钥后）

### 限流 (429)
- **预防**：`RateLimiter` + `RateLimiterMiddleware` 在 HTTP 层主动限流（如微信正文下载默认 5 次/60 秒、微信读书文章列表 2 次/分钟），避免触发 429
- **兜底**：若仍收到应用层频率限制（如响应体 `ret: 200013`），`Retryable` 模块自动重试，指数退避（2s → 4s → 8s）
- 超过重试次数后该帐号标记为失败，任务继续
- API 密钥错误不重试，立即标记帐号失败（由 `CrawlerApiKeyError` mixin 统一识别）；微信 `RateLimitError` 不重试

### 错误阈值
- 累计错误 >= 50（`ERROR_THRESHOLD`）时自动终止**该平台**的剩余帐号（按平台统计 `platform_error_counts`），其他平台继续
- 每个平台独立追踪错误；可通过 `fail_platform!` 立即标记某平台失败

### 帐号级别重试
- 每个帐号独立状态（pending/running/completed/failed）
- 已完成帐号不会被重复抓取
- resume 时自动重置 failed 帐号为 pending

## 实时更新

使用 Stimulus 轮询控制器（`task_poller_controller.js`）更新任务进度：
- 任务详情页自动轮询 `GET /crawl_tasks/:id/poll`，返回 Turbo Stream 替换页面内容
- 指数退避：初始 3 秒，每次 ×1.5，上限 60 秒；状态变化时重置为快速轮询
- 任务进入终态（completed/failed）后服务端返回 204，轮询自动停止
- 标签页隐藏时暂停轮询，恢复可见时立即轮询

## 目录结构

```
mp-crawler/
├── app/
│   ├── controllers/
│   │   ├── accounts_controller.rb
│   │   ├── articles_controller.rb
│   │   ├── crawl_tasks_controller.rb
│   │   ├── dashboard_controller.rb
│   │   ├── profiles_controller.rb
│   │   ├── rss_controller.rb
│   │   ├── sessions_controller.rb
│   │   ├── concerns/ (authentication, authorization, query_persistence)
│   │   ├── admin/ (settings, users, tags, analytics)
│   │   └── api/v1/ (groups, accounts, articles)
│   ├── models/
│   │   ├── account.rb (STI base)
│   │   ├── wechat_account.rb
│   │   ├── rednote_account.rb
│   │   ├── twitter_account.rb
│   │   ├── article.rb
│   │   ├── tag.rb / tag_account.rb / user_tag.rb
│   │   ├── group.rb / group_account.rb
│   │   ├── crawl_task.rb / crawl_task_account.rb / crawl_log.rb
│   │   ├── option.rb / api_key.rb / oauth2_client.rb
│   │   ├── user.rb / session.rb
│   ├── services/
│   │   ├── account_resolver.rb
│   │   ├── accounts/importer.rb
│   │   ├── rednote/importer.rb
│   │   └── twitter/importer.rb
│   ├── jobs/
│   │   ├── crawl_job.rb
│   │   ├── wechat_content_download_job.rb
│   │   ├── cleanup_old_tasks_job.rb
│   │   ├── refresh_activity_counters_job.rb
│   │   └── validate_api_keys_job.rb
│   ├── mailers/
│   │   ├── admin_mailer.rb
│   │   └── application_mailer.rb
│   └── views/
│       ├── accounts/ (index, show, import, import_preview)
│       ├── articles/ (show)
│       ├── crawl_tasks/ (index, show, logs, articles, partials)
│       ├── admin/ (settings, users, tags, analytics)
│       ├── rss/ (index, show, accounts, active_accounts)
│       └── sessions/ (new)
├── lib/
│   ├── crawl_orchestrator.rb  (跨平台统一调度，交替抓取所有帐号)
│   ├── base_crawler.rb        (平台 Crawler 基类/接口)
│   ├── crawler_api_key_error.rb (API 密钥错误通用 mixin)
│   ├── rate_limiter.rb          (通用滑动窗口速率限制器)
│   ├── rate_limiter_middleware.rb (Faraday 速率限制中间件)
│   ├── response_cache_middleware.rb (Faraday 响应缓存中间件)
│   ├── markdown_charset_middleware.rb (正文编码修正中间件)
│   ├── wechat_mp_native_api_client.rb (微信 mp_native API)
│   ├── dajiala_api_client.rb   (大家拉 API)
│   ├── profile_ext_api_client.rb (mitmproxy 凭证 API)
│   ├── weread_api_client.rb    (微信读书转发 API)
│   ├── wechat_crawler.rb       (< BaseCrawler)
│   ├── rednote_api_client.rb
│   ├── tik_hub_api_client.rb   (TikHub 小红书搜索)
│   ├── rednote_crawler.rb      (< BaseCrawler)
│   ├── twitter_api_client.rb
│   ├── twitter_crawler.rb      (< BaseCrawler)
│   └── retryable.rb            (应用层重试 + 抓取任务错误追踪)
├── bin/
│   └── twitter_fetch.py        (Twitter API Python CLI wrapper)
├── db/migrate/
├── config/routes.rb
└── config/recurring.yml        (定时任务：每日抓取 / 正文下载 / 日志清理 / 刷新活跃度计数)
```

## 限制与注意事项

### API 限制
- 微信：每请求最多 20 篇文章，需翻页
- 微信正文下载：默认 5 次/60 秒（`wechat_download_rate_limit` 可配置），由 `RateLimiterMiddleware` 主动限流
- 微信读书（WeRead）：文章列表 2 次/分钟；429 限流的账号当天进入黑名单
- 小红书：分页获取，每页间隔 1 秒
- 各 API 均可能有频率限制，超出时自动重试

### API Key 管理
- 微信（mp_native）Cookie/Token 约 2 小时过期，需重新扫码登录
- 微信读书转发帐号可配置多个，失效/限流的账号会被自动跳过
- Profile Ext 凭证约 25 分钟过期
- 小红书 Key 无过期机制
- 密钥/会话过期后对应平台的帐号抓取失败，任务继续

### 并发控制
- 建议帐号并发：3-5
- 建议文章并发：5-20
- 过高可能触发限流

### 错误阈值
- 累计 50 个错误自动终止**该平台**的剩余帐号（按平台统计）
- 防止无限重试导致资源浪费

### 实时更新机制
- 使用 JS 轮询替代 ActionCable 广播，避免 cable 数据库膨胀问题
- 轮询控制器：`app/javascript/controllers/task_poller_controller.js`
- 轮询端点：`CrawlTasksController#poll` → `poll.turbo_stream.erb`

## 后续计划

- [ ] 高校专业分布数据集成
- [ ] 活动分析看板
- [ ] 文章全文搜索
- [ ] 批量导出功能
- [ ] 邮件通知（抓取完成/失败）
