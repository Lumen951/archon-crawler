# 官网监测

状态：当前实现基线（2026-10-16 核对）。

## 已实现能力

- `WebsiteAccount` 复用账号、任务、活跃度和 RSS 体系，配置入口 URL、抓取模式、最大页面数等元数据。
- Sitemap/robots 等发现逻辑负责找到可监测页面；`MonitorPage` 保存页面，`MonitorPageVersion` 保存版本，`MonitorChange` 保存变化记录。
- Listing 模式使用生成或配置的 `crawl_rule`，从列表页发现详情 URL 并同步为 `Article`；规则未配置或入口不可用时要产生可见错误。
- 页面检查由 `WebsiteCrawler` 执行，`ArticleSynchronizer` 负责正文基线、版本和变化检测；失败页记录状态、错误和错误次数。
- 账号级状态会记录最近检查状态、最近变化和错误；监测结果可通过变化页面及 RSS 查询。
- `MonitorChange` 存储摘要、重要性、相关性、实体与分析状态，当前重要性阈值为 7；`notified_at` 是预留通知锚点，不能由字段存在推断已实现自动通知。

## 与常规文章抓取的区别

Sitemap 模式的事实单位包含页面版本和变化，同时也同步文章。Listing 模式使用 `WebsiteCrawler::ListingArticleSynchronizer` 将详情 URL 同步为文章，列表入口本身不创建 `MonitorPage` 或版本。不要把两种模式的产物混为一谈，也不要把监测模型套用到微信、小红书或 Twitter。

网站抓取出错不能静默当成空 feed：发现失败、所有页面失败、规则不完整和部分页面失败应保留不同的日志与账号状态。

## 代码与测试入口

- [app/models/website_account.rb](../../app/models/website_account.rb)、[app/models/monitor_page.rb](../../app/models/monitor_page.rb)、[app/models/monitor_page_version.rb](../../app/models/monitor_page_version.rb)、[app/models/monitor_change.rb](../../app/models/monitor_change.rb)
- [lib/website_crawler.rb](../../lib/website_crawler.rb)（内含 `WebsiteCrawler::ArticleSynchronizer`，不是单独的文件）
- [app/services/website/](../../app/services/website/)、[app/jobs/generate_website_listing_rule_job.rb](../../app/jobs/generate_website_listing_rule_job.rb)
- [test/lib/website_crawler_fetcher_test.rb](../../test/lib/website_crawler_fetcher_test.rb)、[test/lib/website_listing_crawler_test.rb](../../test/lib/website_listing_crawler_test.rb)、[test/lib/article_synchronizer_test.rb](../../test/lib/article_synchronizer_test.rb)

## 状态与验证边界

### 机器人官网定时监测（2026-10-27）

`config/robot_websites.yml` 保存首批 16 家公司的同站新闻列表规则及选定产品页。
`Website::Importer.import_robot_websites` 幂等导入，不覆盖未归入该批次的已有账号，也不重新启用被人工停用的账号。
`WebsiteAccount.enqueue_robot_checks` 通过既有 `CrawlTask` / `CrawlJob` 入队，按北京时间每天 08:00 检查全组，20:00 加查智元、擎朗和 Hexagon。同一时段重复调度、已有待运行/运行中/暂停任务不会重复创建；每家公司错开 45 秒。

Listing 可通过 `monitor_pages` 配置同站页面和正文选择器，独立建立版本基线，每个自然日成功检查一次。配置区域缺失、正文不足或网络失败记录真实错误。官网新闻目录可以单独配置为 `news`，用于发现外链新闻变化；外站正文不在此规则的自动抓取范围内。

开启 `weekly_review` 后，日常检查跳过已有完整正文；首次和距离上次成功复查满七天时，检查配置的额外分页并复查正文。每轮最多 50 个去重新闻 URL，未配置的更深历史分页不自动遍历。只有整轮成功才推进复查时间。发布日期来自列表字段或详情页时间元数据，缺失时保留为空，不使用抓取时间代替。

本次 Archon 服务器使用独立 recurring 配置，只开启本组监测；不同时开启仓库中其它平台的周期任务。未配置付费渲染和模型密钥时，抓取、版本比较均在服务器执行。

Sitemap 路径仍可能记录账号级错误但将任务成员标记为完成。Listing 路径会在入口、正文或配置监测页失败时将成员标记为失败。验收同时核对账号、页面、正文和任务状态。

现有测试覆盖首次基线不产生变化、内容未变不增加版本、变化后更新文章、不覆盖其它账号文章、持久化中途失败回滚。参见 [test/lib/article_synchronizer_test.rb](../../test/lib/article_synchronizer_test.rb)。这些是可定位的测试，不代表本次已执行通过。
