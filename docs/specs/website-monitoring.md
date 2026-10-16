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

部分检查路径会记录账号级错误，但将任务成员标记为完成；成员完成不等于全部页面抓取成功。本轮只记录现状，不改变该语义。修改时应同时核对账号、页面和任务状态。

现有测试覆盖首次基线不产生变化、内容未变不增加版本、变化后更新文章、不覆盖其它账号文章、持久化中途失败回滚。参见 [test/lib/article_synchronizer_test.rb](../../test/lib/article_synchronizer_test.rb)。这些是可定位的测试，不代表本次已执行通过。
