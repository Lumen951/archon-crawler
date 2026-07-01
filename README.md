# MP-Crawler

微信公众号文章爬虫和RSS订阅服务

A Ruby on Rails application for crawling WeChat official account articles and providing RSS feeds.

## 功能特性 / Features

- 🔍 **公众号管理** - Import and manage WeChat official accounts
- 📰 **文章抓取** - Async concurrent crawling with pause/resume support
- 📅 **定时调度** - Schedule automatic crawls (hourly/daily/weekly)
- 📡 **RSS订阅** - Generate RSS feeds for each account
- ⚡ **高性能** - Async gem with semaphore for concurrent requests
- 💾 **断点续传** - Save progress and resume from where you left off

## 技术栈 / Tech Stack

- Ruby on Rails 8.1
- SQLite3
- TailwindCSS with CSS custom properties
- Async gem (concurrent crawling in Puma process)
- Stimulus.js & Turbo

## 快速开始 / Quick Start

### 1. 安装依赖 / Install Dependencies

```bash
bundle install
```

### 2. 数据库设置 / Database Setup

```bash
rails db:create db:migrate
```

### 3. 导入公众号 / Import Accounts

**Option 1: Web UI (Recommended)**

1. Start the server: `rails server`
2. Visit http://localhost:3000/admin/accounts
3. Click "Import Accounts" button
4. Choose to paste JSON or upload a file
5. Submit to import

**Option 2: Command Line**

```bash
# Make sure wechat_accounts_import_final.json exists in project root
rails import:accounts
```

### 4. 配置 API Key / Configure API Key

```bash
rails console
SystemConfig.set('wechat_api_key', 'your-key-here', expires_at: 4.days.from_now)
SystemConfig.set('default_concurrency', '10')
```

获取 API Key: https://down.mptext.top/dashboard/api

⚠️ **重要**: API Key 每4天过期，需要重新登录获取

### 5. 启动服务 / Start Server

```bash
# Development
bin/dev

# Or directly
rails server
```

访问: http://localhost:3000

## 使用指南 / Usage Guide

### 手动抓取 / Manual Crawling

1. 访问 `/admin/accounts`
2. 点击账号卡片上的 "Crawl Now" 按钮
3. 在 `/admin/crawl_jobs` 查看抓取进度

### 定时抓取 / Scheduled Crawling

1. 访问 `/admin/crawl_schedules`
2. 选择公众号、频率和并发数
3. 创建定时任务
4. 添加 cron job:

```bash
*/15 * * * * cd /path/to/mp-crawler && rails crawl:execute_schedules
```

### RSS 订阅 / RSS Feed

每个公众号的 RSS 地址:

```
http://localhost:3000/rss/{fakeid}
```

例如:
```
http://localhost:3000/rss/MzkzNjIwNjYwOQ==
```

## 目录结构 / Project Structure

```
mp-crawler/
├── app/
│   ├── controllers/
│   │   ├── admin/              # Admin dashboard
│   │   └── rss_controller.rb
│   ├── models/                 # 5 models
│   └── views/
│       ├── admin/              # Admin UI
│       ├── shared/             # Reusable partials
│       └── rss/
├── lib/
│   ├── wechat_api_client.rb   # API wrapper
│   ├── wechat_crawler.rb      # Async crawler
│   └── tasks/
│       ├── import.rake         # Import accounts
│       └── scheduler.rake      # Execute schedules
└── config/
    └── routes.rb
```

## API 端点 / API Endpoints

使用 WeChat Article Exporter API:

- Base URL: `https://down.mptext.top`
- 认证: `X-Auth-Key` header
- 主要接口:
  - `GET /api/public/v1/article` - 获取文章列表
  - `GET /api/public/v1/download` - 下载文章内容

## 并发控制 / Concurrency Control

系统使用 `async` gem 在 Puma 进程中实现并发:

- 全局默认并发数: 10 (可在设置中修改)
- 每个定时任务可独立设置并发数
- 使用 Semaphore 控制同时进行的请求数量

```ruby
Async do |task|
  semaphore = Async::Semaphore.new(concurrency)
  articles.each do |article|
    semaphore.async { fetch_article(article) }
  end
end
```

## 错误处理 / Error Handling

- **API Key 过期**: 自动暂停所有任务
- **限流 (429)**: 自动重试，指数退避
- **网络错误**: 最多重试3次，保存进度
- **重复文章**: 自动跳过

## 故障排查 / Troubleshooting

### 抓取失败

1. 检查 API Key 是否有效
2. 查看 CrawlJob 的 error_message
3. 确认网络连接
4. 验证公众号已开启搜索功能

### 无法访问

```bash
# 重新编译 TailwindCSS
rails tailwindcss:build

# 检查路由
rails routes | grep admin
```

## 开发 / Development

```bash
# Run tests (if added)
rails test

# Check routes
rails routes

# Database console
rails dbconsole

# Rails console
rails console
```

## 限制 / Limitations

- API Key 每4天过期，需手动更新
- 每次请求最多20篇文章
- 可能遇到限流（建议并发5-20）
- SQLite3 适合中小规模，大规模建议 PostgreSQL

## 贡献 / Contributing

欢迎提交 Issue 和 Pull Request!

## License

MIT

## 相关链接 / Links

- WeChat Article Exporter: https://down.mptext.top
- API 文档: https://documenter.getpostman.com/view/1276582/2sB3QDuXUa
