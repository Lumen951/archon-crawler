# MP-Crawler

微信公众号文章爬虫和RSS订阅服务

## 项目简介

MP-Crawler 是一个基于 Ruby on Rails 的应用，用于自动抓取微信公众号文章并提供 RSS 订阅服务。主要面向高校帐号，支持定时抓取、进度保存、断点续传等功能。

## 技术栈

- **Framework**: Ruby on Rails 8.1
- **Database**: SQLite3
- **CSS**: TailwindCSS with CSS custom properties
- **Concurrency**: Async gem with semaphore (runs in Puma process)
- **Frontend**: Stimulus.js, Turbo

## 核心功能

### 1. 帐号管理
- 从 JSON 文件导入帐号列表（支持粘贴或上传）
- 网页界面导入：支持直接粘贴 JSON 或上传文件
- 命令行导入：`rails import:accounts`
- 查看帐号详情和文章列表
- 设置帐号状态（活跃/不维护）
- 手动触发抓取

### 2. 文章抓取
- 使用 WeChat Article Exporter API 抓取文章
- 异步并发抓取（可配置并发数）
- 支持暂停和恢复
- 自动保存进度，支持断点续传
- 同时保存 Markdown 和 HTML 格式
- 支持重试失败帐号（任务运行中或完成后均可）

### 3. 定时调度
- 支持按小时/天/周定时抓取
- 每个帐号可设置独立的抓取计划
- 可配置每个计划的并发限制

### 4. RSS 订阅
- 每个帐号提供独立的 RSS feed
- 访问地址: `/rss/{fakeid}`
- 自动包含最近 50 篇文章

### 5. API Key 管理
- 支持手动更新 API Key
- 自动检测 Key 过期状态
- Key 即将过期时显示警告

## 架构设计

### 数据模型

```
Account (帐号)
├── has_many :articles
├── has_many :crawl_task_accounts
└── has_many :crawl_tasks, through: :crawl_task_accounts

Article (文章)
└── belongs_to :account

CrawlTask (抓取任务)
├── has_many :crawl_task_accounts
├── has_many :crawl_logs
└── has_many :articles

CrawlTaskAccount (帐号抓取状态)
├── belongs_to :crawl_task
├── belongs_to :account
└── enum status: { pending: 0, running: 1, completed: 2, failed: 3 }

CrawlSchedule (抓取计划)
└── belongs_to :account

Option (系统配置)
- 存储 API Key 和全局设置
```

### 核心服务

**WechatApiClient** (`lib/wechat_api_client.rb`)
- 封装微信文章导出 API
- 自动重试机制（3次，指数退避）
- 错误处理：Key 过期、限流、网络错误

**WechatCrawler** (`lib/wechat_crawler.rb`)
- 异步并发抓取引擎
- 使用 Async::Semaphore 控制并发数
- 在 Puma 进程中运行（无需 background job）
- 自动保存进度，支持暂停/恢复

### API 接口

使用 WeChat Article Exporter 的 API：
- Base URL: `https://down.mptext.top`
- 认证方式: `X-Auth-Key` header
- Key 有效期: 4天（用户需每5天手动更新）

主要接口：
- `GET /api/public/v1/article` - 获取文章列表
- `GET /api/public/v1/download` - 下载文章内容

## 开发指南

### 环境要求

- Ruby 3.3+
- Rails 8.1
- SQLite3

### 初始化

```bash
# 安装依赖
bundle install

# 创建数据库
rails db:create db:migrate

# 导入帐号列表
rails import:accounts

# 设置 API Key
rails console
Option.set('wechat_api_key', 'your-key-here')
Option.set('wechat_api_key_expires_at', 4.days.from_now.iso8601)
Option.set('default_concurrency', '10')
```

### 启动服务

```bash
# 开发环境
bin/dev

# 或直接启动 Rails
rails server
```

### 定时任务

添加 cron 任务执行定时抓取：

```bash
*/15 * * * * cd /path/to/mp-crawler && rails crawl:execute_schedules
```

## 使用说明

### 1. 导入帐号

有三种方式导入帐号：

**方式一：网页导入（推荐）**
1. 访问 `/admin/accounts` 点击 "Import Accounts" 按钮
2. 选择 "Paste JSON" 或 "Upload File"
3. 粘贴 JSON 数据或上传 JSON 文件
4. 点击导入按钮

**方式二：命令行导入**
```bash
# 将 JSON 文件放在项目根目录，命名为 wechat_accounts_import_final.json
rails import:accounts
```

**方式三：下载模板**
在导入页面下载示例模板，填写后上传

### 2. 配置 API Key

访问 `/admin/settings`，输入从 https://down.mptext.top/dashboard/api 获取的 API Key。

⚠️ **重要**: API Key 每4天过期，需要重新登录获取。

### 3. 查看帐号

访问 `/admin/accounts` 查看所有导入的帐号。

### 3. 手动抓取

在帐号列表页点击"Crawl Now"按钮开始抓取。

抓取过程：
1. 系统创建 CrawlTask 记录
2. 异步并发下载文章列表和内容
3. 自动保存进度（每20篇更新一次）
4. 可随时暂停/恢复

### 4. 重试失败帐号

当抓取任务中有帐号失败时，可以重试这些失败的帐号：

**任务运行中**：
- 点击"重试失败帐号 (N)"按钮
- 系统会先暂停当前任务，然后重试失败的帐号
- 已完成的帐号不会被重复抓取

**任务完成后**：
- 如果任务完成但有失败帐号，同样显示"重试失败帐号"按钮
- 点击后会重新启动任务，只处理失败的帐号

**按钮显示逻辑**：
| 任务状态 | 有失败帐号 | 显示按钮 |
|---------|-----------|---------|
| 运行中 | 是 | 重试失败帐号 + 暂停 + 标记失败 |
| 运行中 | 否 | 暂停 + 标记失败 |
| 暂停/失败 | 是 | 重试失败帐号 |
| 暂停/失败 | 否 | 恢复 |
| 完成 | 是 | 重试失败帐号 |
| 完成 | 否 | 无按钮 |

### 5. 设置定时抓取

访问 `/admin/crawl_schedules`：
1. 选择帐号
2. 设置频率（hourly/daily/weekly）
3. 设置并发数（5-50）
4. 启用计划

### 5. 订阅 RSS

每个帐号的 RSS 地址：
```
https://your-domain.com/rss/{fakeid}
```

例如：
```
https://your-domain.com/rss/MzkzNjIwNjYwOQ==
```

## 并发控制

系统使用 `async` gem 在 Puma 进程中实现并发，无需额外的 background job 系统。

### 并发级别

- **全局默认**: 通过 Option 设置（推荐 10）
- **计划级别**: 每个 CrawlSchedule 可独立设置
- **手动触发**: 使用全局默认值

### Semaphore 机制

```ruby
Async do |task|
  semaphore = Async::Semaphore.new(concurrency)
  
  articles.each do |article|
    semaphore.async do
      # 并发下载文章内容
      fetch_and_save_article(article)
    end
  end
end
```

同时最多有 `concurrency` 个文章在下载，避免过载 API。

## 错误处理

### API Key 过期
- 所有运行中的任务自动暂停
- 后台显示警告提示
- 更新 Key 后可恢复任务

### 限流 (429)
- 自动重试，指数退避（1s → 2s → 5s → 10s）
- 超过重试次数后标记任务失败
- 保留已抓取的进度

### 网络错误
- 每个请求最多重试 3 次
- 失败后保存进度，可手动重试
- 错误信息记录在 CrawlTaskAccount.error_message

### 帐号级别重试
- 每个帐号独立追踪状态（pending/running/completed/failed）
- 任务完成后可单独重试失败的帐号
- 已完成的帐号不会被重复抓取
- 重试时会重置失败帐号的状态为 pending

### 重复文章
- 使用 `articles.url` 唯一索引
- 遇到重复自动跳过
- 不影响整体抓取流程

## 性能优化

### 1. 异步并发
- 使用 Async::Semaphore 控制并发数
- 避免串行等待，大幅提升速度
- 在 Puma 进程中运行，无额外开销

### 2. 进度保存
- 每 20 篇文章更新一次进度
- 避免频繁数据库写入
- 支持断点续传

### 3. 去重机制
- URL 唯一索引，数据库层面去重
- 跳过已存在文章，减少 API 调用

## 限制与注意事项

### API 限制
- 每个请求最多返回 20 篇文章
- 需要翻页获取全部文章
- 可能存在频率限制（需监控 429 错误）

### API Key 管理
- Key 每 4 天过期
- 需要人工登录 https://down.mptext.top 更新
- 过期后所有抓取自动暂停

### 并发控制
- 建议并发数: 5-20
- 过高可能触发限流
- 过低影响抓取速度

### 数据存储
- 使用 SQLite3，适合中小规模
- 大规模部署建议切换到 PostgreSQL
- 文章内容存储为 TEXT，注意大小限制

## 目录结构

```
mp-crawler/
├── app/
│   ├── controllers/
│   │   ├── admin/          # 管理后台控制器
│   │   └── rss_controller.rb
│   ├── models/             # 数据模型
│   └── views/
│       ├── admin/          # 管理后台视图
│       └── rss/            # RSS builder
├── lib/
│   ├── wechat_api_client.rb    # API 客户端
│   ├── wechat_crawler.rb       # 抓取引擎
│   └── tasks/
│       ├── import.rake         # 导入任务
│       └── scheduler.rake      # 定时任务
├── db/
│   └── migrate/            # 数据库迁移
└── config/
    └── routes.rb           # 路由配置
```

## 后续计划

- [ ] 高校专业分布数据集成
- [ ] 活动分析看板
- [ ] 文章全文搜索
- [ ] 批量导出功能
- [ ] API 接口（供第三方调用）
- [ ] 邮件通知（抓取完成/失败）

## 故障排查

### 抓取失败
1. 检查 API Key 是否有效
2. 查看 CrawlJob.error_message
3. 检查网络连接
4. 确认帐号是否开启搜索

### 无法启动抓取
1. 检查是否有活跃的 CrawlJob
2. 确认 API Key 未过期
3. 查看 Rails log 错误信息

### RSS 无内容
1. 确认帐号已抓取文章
2. 检查 Article 表是否有数据
3. 确认 fakeid 正确

## 贡献指南

欢迎提交 Issue 和 Pull Request！

## License

MIT
