# 每日简报规格

状态：已确认并实现首版（2026-11-03）

## 需求与目标

用户希望后台每天自动汇总新采集的文章与论文，按技术、商业化和活动内容整理成简报，并在站内阅读。活动行采集也纳入同一日报；08:00 开始排队采集，简报在 09:00 生成。

首版复用现有 `LlmClient`，不调用自主 Agent，不增加飞书或其他外部推送。报告保存在数据库，登录用户可查看列表和详情。

## 日期与来源

- 每天北京时间 09:00 生成前一自然日的简报。
- 文章和论文以数据库 `created_at` 判断是否在前一自然日新入库，不使用来源发布时间替代入库时间。
- 活动行账号由 `WebsiteAccount.metadata.monitoring_group == "event_sources"` 识别。除前一日文章外，补入简报运行当天 00:00 至生成时已入库的活动文章。
- 08:00 定时项仅负责创建并排队采集任务，不能保证全部站点在 09:00 前完成。晚于生成时刻入库的内容不会回写已完成报告。
- 每次最多选取 80 条来源；每条正文片段最多 4,000 字符。报告记录实际输入文章与论文数量。

## 分类与格式

- 技术文章和论文：摘要、结果、核心方法。
- 商业化内容：行业趋势、核心问题、进攻方向、用户定位、时间节奏、目标要求，与 `专业CEO分析.md` 标题一致。
- 活动行文章：活动名称、活动时间、地点、主办方、报名方式和简要说明。来源没有提供的信息留空。
- 混合或无法判断的内容归为“其他”，不强行套用技术或商业化结构。
- 中文表达遵循用户提供的写作要求：交代句间逻辑、控制修饰层级、避免抽象主语密集出现、检查日常搭配并删去没有业务信息的句子。

## 数据和任务边界

- `DailyReport.report_date` 唯一，每个日期最多一条报告；状态为待处理、运行中、已完成或失败。
- `DailyReportJob` 负责生成和失败记录；`DailyReportGenerator` 读取文章、论文并调用 `LlmClient`。
- 模型只能引用当前输入来源的 `source_type` 和 `source_id`。服务过滤无效 ID，并将可信来源 URL 附回结果。
- 没有来源时保存空 `items` 并标记完成；LLM 请求或结构解析失败时标记失败并记录截断后的错误信息。
- 页面只读，不提供手动触发、修改内容或外部发送功能。

## 角色与页面

登录用户通过 `/daily_reports` 查看最近 60 份简报，并从 `/daily_reports/:id` 阅读内容。页面访问沿用全站登录认证。

## 验收条件

- 周期任务在开发和生产环境每天北京时间 09:00 入队。
- 简报只统计前一自然日新入库的普通文章与论文，并包含运行当天已入库的活动行文章。
- 技术、商业化、活动和不确定类型各自使用对应字段；无活动字段时不编造。
- 空数据成功生成空报告；LLM/API 或返回格式失败留下失败状态和原因。
- 无效来源 ID 不会进入已保存内容；单次来源和正文长度有硬上限。
- 通过离线测试验证 Job、服务和页面；外部 LLM 必须 mock。

## 代码与测试锚点

- 模型：[app/models/daily_report.rb](../../app/models/daily_report.rb)
- Job：[app/jobs/daily_report_job.rb](../../app/jobs/daily_report_job.rb)
- 生成服务：[app/services/daily_report_generator.rb](../../app/services/daily_report_generator.rb)
- 控制器：[app/controllers/daily_reports_controller.rb](../../app/controllers/daily_reports_controller.rb)
- 调度：[config/recurring.yml](../../config/recurring.yml)
- 测试：[test/models/daily_report_test.rb](../../test/models/daily_report_test.rb)、[test/jobs/daily_report_job_test.rb](../../test/jobs/daily_report_job_test.rb)、[test/services/daily_report_generator_test.rb](../../test/services/daily_report_generator_test.rb)、[test/controllers/daily_reports_controller_test.rb](../../test/controllers/daily_reports_controller_test.rb)

## 未决事项

- 首版不重跑落后的活动行采集任务。若实测 08:00 后普遍无法在 09:00 前完成，后续再评估增加缓冲时间或延迟生成。
- 首版不向飞书推送，也不提供手动重试页面。
