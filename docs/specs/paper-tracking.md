# 论文导入与追踪

状态：单篇导入已通过本地回归和 arXiv 真实联调；OpenReview 真实论文读取受 403 阻塞。阶段 0/1 已获批准，结果见第 10 节；未部署。作者关注、会议订阅和版本历史仍是后续目标。

日期：2026-10-19（阶段 0/1 验证与作者位置规则）。

相关入口：[规格地图](README.md)、[现有架构](../architecture/README.md)、[运行手册](../runbook/README.md)。

## 1. 需求依据与本次边界

用户已确认的方向：

- arXiv 与 OpenReview 合并为一个“论文导入”入口，不按供应商拆成两个产品页面。
- 从种子论文解析作者，用于后续作者论文追踪。
- 支持会议论文追踪，重点关注具身智能。
- 暂不接入 Google Scholar，优先完成 arXiv、OpenReview 和相关会议。
- 用户已查看设计并同意按此方向继续开发；当前先提交文档基线、核实本地验证环境，再推进实现。

下文的页面组织、领域划分和部署方向作为后续实现依据；当前落地范围与差异见以下验收记录，不能用文档存在代替完整连通性、覆盖率或测试结果。

### 2026-10-18 单篇导入验收记录（历史，最新结果见第 10 节）

- 当前代码提供 `/papers`、`/papers/import`、论文详情及个人导入任务页面；arXiv/OpenReview 共用入口，后台逐条导入，每批最多 20 条。论文元数据共享，任务详情与轮询限定当前用户。
- 实体采用 Paper、PaperSource、PaperAuthor、PaperAuthorship、PaperImportTask 和 PaperImportItem。仅保存来源最新元数据；尚未实现版本快照、作者关注、会议订阅、跨来源合并或自动发现。
- Docker 隔离测试库中，通过应用 `PaperImporter` 实际导入 Richard Sutton 署名论文 `2608.01475`（Plasticity of Growing and Elastic Neural Networks in Online Continual Learning）与 `2606.19357`（Physical Atari: A Robust and Accessible Platform for Real-time Reinforcement Learning on Robots），核对到标题、完整作者顺序及首次发表时间。姓名查询仅用于选择样本，不证明作者身份匹配或论文覆盖率。
- 服务、Job 和控制器共 19 项测试、96 个断言通过；覆盖重复链接、同名作者隔离、原子落库、公开作者 ID、时间、错误响应、任务重投、越权访问和结果轮询。Zeitwerk 检查通过（现有 `app/mcp_server` 不在 eager-load 范围）。
- arXiv 请求与写入暂由 PostgreSQL advisory lock 串行化，每次请求前等待三秒；该方式会占用数据库连接和 worker。尚未验证多进程崩溃场景；后续订阅调度不能直接扩大此实现的并发规模。
- 网络失败当前记录失败，用户重新提交；没有自动网络重试、调度恢复或暂停功能。running 任务重新投递时可继续 pending 项，但尚无自动故障任务回收器。
- OpenReview 成功与失败已用离线报文验证，真实接口成功导入仍待核实。已有样本 403 不能当作无论文或接入成功。
- 浏览器定向用例及合成响应已添加；独立浏览器数据库准备因自动审批服务连接错误未执行，浏览器验证尚未完成。提交前还需补齐迁移 schema、最终检查与浏览器验收。

### 2026-10-18 实现准备记录

- arXiv：公开查询 `1706.03762` 返回 HTTP 200，解析到标题、8 位作者、`v7` 版本及发表/更新时间。
- OpenReview：CoRL 2025 主会 group 查询返回 HTTP 200，取得投稿名称和 venue 状态配置；同一环境按录用 venue 查询一条论文返回 HTTP 403，原因尚未定位，不能判定没有论文或声称接入完成。
- 当时尚未执行数据库迁移、业务代码开发或生产部署；后续本地实现与验证见上一节。实际样本响应未保存进仓库。

### 第一版建议范围

| 能力 | 范围 |
|---|---|
| 单篇导入 | 接受 arXiv 和 OpenReview 论文链接，异步解析元数据，逐条展示成功或失败 |
| 作者关注 | 从论文选择作者；根据来源标识或姓名检索发现候选论文，并支持人工确认 |
| 会议订阅 | 输入已支持的 OpenReview venue 链接，确认年份、track 和公开数据范围 |
| 论文动态 | 区分新发现论文、arXiv 新版本、公开录用状态变化 |
| 跨来源关联 | 同一研究成果可以保留两个来源，弱证据只生成待确认关联 |
| 运行证据 | 记录同步状态、分页进度、数量、失败原因和重试结果 |

第一轮拟以 CoRL、RSS 的一个已公开年份验证，再扩展 ICLR、NeurIPS、ICML；具体年份及 track 在样本验证时确认。使用 OpenReview 不代表投稿、作者或评审全部公开。

### 不在第一版承诺范围内

Google Scholar、第三方 Scholar 服务、跨网站个人动态、引用计数追踪、PDF 全文下载和托管、自动研究报告、飞书推送、新的 REST/MCP 接口，以及 ICRA/IROS 等需要其他数据源的接入。也不把“任意会议官网链接自动适配”或“新年份自动无误接入”作为第一版能力。

## 2. 前端：一个入口，三类对象

沿用现有 ERB、Turbo、Stimulus、Tailwind 和 Archon 视觉样式，不引入 React、独立前端工程或新的构建服务。建议导航新增“论文”，主操作统一叫“论文导入”。

### 页面草图

```text
论文                                              [论文导入]
[论文库]  [关注作者]  [订阅会议]

作者 / 会议 / 来源 / 时间 / 状态筛选
------------------------------------------------------------
论文标题                              新发现 / 新版本 / 已录用
作者列表 · 会议及年份 · 首次发表时间
发现原因：关注作者命中 / 会议订阅命中 / 手动导入
来源：arXiv | OpenReview                 [详情] [待确认关联]
```

```text
论文导入
[粘贴论文或 OpenReview 会议链接，每行一个                 ]
[解析链接]

解析结果：
- 论文：标题、作者、来源、是否已存在       [导入] [选择关注作者]
- 会议：名称、年份、track、公开范围       [确认订阅]
- 失败：具体链接与可解释原因             [修正后重试]
```

会议订阅确认页提供：只跟踪该届、录用论文或公开投稿、是否包含 Workshop、历史回溯范围、全部论文或具身主题筛选。无法读取的选项不能承诺支持。第一版建议默认只订阅明确的年度主会、仅录用论文；这是待确认默认值。

### 页面职责与拟议路由

| 页面 | 拟议路由 | 主要内容 |
|---|---|---|
| 论文库 | `/papers` | 搜索、筛选、分页、来源与发现原因；支持批量结果但不一次加载全部记录 |
| 统一导入 | `/papers/import` | 类型识别、异步解析、确认、重复与失败提示 |
| 论文详情 | `/papers/:id` | 摘要、按序作者、来源链接、版本、venue、状态历史和匹配证据 |
| 关注作者 | `/paper_authors` | 种子论文、确认身份、候选成果、暂停关注与手动同步 |
| 订阅会议 | `/paper_venues` | 年份/track、公开范围、过滤条件和同步状态 |
| 运行详情 | `/paper_sync_runs/:id` | 任务阶段、进度、数量、失败项和重试入口 |

当前已创建论文库、统一导入、论文详情及 `/paper_import_tasks/:id` 任务页；作者、会议和同步运行页面仍待实现。读请求只查询；导入、订阅、确认、暂停和重试使用带 CSRF 保护的写请求，不能由 GET 或 Turbo 预取触发。

后台任务进度拟复用现有 `task_poller_controller.js` 的交互模式。是否直接复用该控制器，取决于任务状态和返回格式是否兼容，不先修改共享逻辑。

空结果、等待限流、部分失败、作者匿名、元数据缺失和身份待确认应分别显示。移动端保留导入、筛选和核心论文信息，不将桌面宽表直接压缩。

## 3. 后端：论文领域独立，基础设施复用

现有 `Article` 仅属于一个 `Account`，URL 全局唯一；账号删除会删除其文章。这不适合一篇论文关联多位关注作者。因此不改变现有文章归属，也不把作者直接塞进常规文章抓取管线。

建议新增论文领域模型，但复用 Rails、PostgreSQL、登录权限、Active Job、Solid Queue 和任务展示习惯。不要把论文写入官网监测模型或复用活动研究任务来混淆业务状态。

### 逻辑数据模型（待评审，非最终表结构）

| 对象 | 拟议职责与关键约束 |
|---|---|
| Paper | 一项论文成果的聚合记录；展示字段需要可追溯到来源，不覆盖来源差异 |
| PaperSource | 关联 Paper；保存来源类型、外部 ID、URL、原始元数据及来源时间；`来源 + 外部 ID` 唯一 |
| PaperSourceRevision | 保存已观测的版本/状态快照；以来源版本或内容摘要去重；不声称补齐全部历史版本 |
| PaperAuthor | 内部作者身份；姓名不是唯一键；外部身份映射保存来源与确认依据 |
| PaperAuthorship | 记录来源论文上的作者署名和顺序，可关联已确认作者；匿名/未确认署名不能强制绑定身份 |
| PaperVenue | 表示具体会议年份和 track，保存真实 venue ID、系列名和公开能力；不推算下一年 ID |
| PaperSubscription | 关注某位作者或具体 venue，记录归属、范围、频率、启停和同步检查点 |
| PaperSubscriptionMatch | 记录订阅与论文的命中关系、证据和待确认/确认/排除状态；同一论文允许命中多项订阅 |
| PaperSyncRun / Item | 记录一次导入或同步及各项结果，支持部分失败、分页恢复、重投防护和审计 |

这是逻辑对象清单，不要求每行都独立建表；实现前根据查询、唯一约束及审计需求确定实体与 JSON 的边界，再提交迁移和文件清单。

建议公开论文元数据在站内共享，个人订阅与匹配操作归当前用户；全站订阅配置由管理员管理。此权限方案尚待确认，控制器需复用现有授权机制并验证对象级访问。取消关注只改变订阅，不删除共享论文、作者或运行证据。

### 应用分层

- 控制器：校验输入和权限，创建任务，返回状态或页面，不进行长时间外部请求。
- 应用服务：链接识别、导入确认、订阅管理、字段归一、跨来源匹配。
- API 客户端：分别处理 arXiv Atom XML 和 OpenReview JSON，隔离分页、限流、错误与字段差异。
- Job：执行导入、订阅同步和到期分发，任务提交后入队，处理重复与晚到投递。
- 模型：持久化、唯一约束、关联及任务状态转换。

继续使用既有 `app/models`、`app/jobs`、`app/services`、`lib`、`app/controllers`、`app/views` 和 `test` 结构。具体文件和子目录另行列出审批，不在文档阶段创建骨架。

## 4. 抓取、匹配与增量同步

### arXiv

1. 校验 URL 主机和路径，只从已支持链接提取 ID；请求固定官方 API，而不是任意抓取用户 URL。支持新旧 ID、abs/pdf 链接及版本后缀的具体范围由测试明确。
2. 按 `id_list` 查询元数据，解析 Atom 命名空间；不依赖 PDF 提取作者。XML 禁用外部实体和网络解析。
3. 不带版本号的 ID 作为来源身份，版本号另存；首次发表、来源更新、本地观测时间分别保存。
4. 作者姓名搜索只生成候选；种子论文、共同作者等用于辅助确认，不能把主题相似当成同一人。
5. 作者检索使用分页与重叠回溯，定期重查已跟踪论文，避免只按初次发表日期漏掉修订。
6. 全部受控 worker 共用单连接和至少三秒请求间隔；单个 Job 内 sleep 或进程内锁不足以证明全局限流。计划用数据库协调的请求闸门并测试跨进程行为，不新增 Redis。

### OpenReview

1. 论文链接提取 Note/Forum ID，会议链接提取真实 group ID，读取 API v2 的公开数据。
2. 按 venue group 与 invitation 确定投稿入口，处理 `content.<field>.value`，不能将 v1 示例直接用于 v2。
3. 分页抓取公开论文，根据 venue 配置解释录用、在审、撤稿等状态；未返回决定不等于拒稿。
4. 公开作者标识可用于身份绑定；匿名署名保持匿名，不猜测作者。不尝试读取未授权评审。
5. 新增论文同步之外，定期复查已知 Note 的版本、公开字段和决定；评审回复变更不一定意味着主论文创建时间改变。
6. 历史 API v1 venue 第一版明确提示暂不支持，不能将读取失败记为空论文集。

CoRL 2026 官方说明录用论文及评审在决定公布后公开；RSS 2026 官方说明论文录用后公开、评审不公开。能力提示应按年度配置和实测维护，而非按平台写死。

### 去重与匹配

- 同来源以外部 ID 幂等更新；arXiv 新版本不是新论文。
- 跨来源优先采用明确的 arXiv 引用、经过核对的 DOI 等证据；标题、作者组合只用于候选关联。
- 未经确认不进行不可逆合并；保留来源记录，设计人工确认、拒绝和纠正入口。
- 同一论文被作者和会议同时命中，论文库只展示一项，并保留两个发现原因。
- 匿名 OpenReview 论文不因标题相似自动绑定 arXiv 作者，身份关联待公开证据或人工确认。
- 具身主题筛选先采用可解释的标题/摘要关键词规则，保留命中依据；默认不依赖 LLM，不将规则未命中宣称为绝对不相关。

### 调度与失败处理

建议订阅默认每天同步一次，首次历史回溯范围在确认页选择；这不是实时、无遗漏承诺，也不沿用社交账号的停更分层规则。

每次运行固定范围、截止边界与分页预算。完成本轮所有分页后才能推进完整同步检查点；达到预算但尚未结束时标记待续，不显示完成。重叠窗口与周期性对账用于处理迟到记录和分页变化，单靠时间戳不能保证完整性。

任务状态建议包含 pending/running/paused/completed/failed，部分失败通过子项结果明确展示。暂停阻止启动下一项，正在执行的请求允许在超时范围内结束；恢复保留已完成项。重复投递通过运行归属校验、唯一约束和执行租约防护；旧 Job 不能覆盖新运行状态。

429、临时网络错误和可重试服务端错误采用有界退避，并遵守服务端重试提示。输入错误、权限拒绝和不支持来源单独记录。未发现论文与请求失败必须区分；超过重试上限保留可操作的失败状态。

## 5. 前后端如何部署

### 当前仓库配置事实

- [Gemfile](../../Gemfile) 使用 Rails 8.1、Turbo、Stimulus、Tailwind、Faraday 和 Nokogiri。
- [Dockerfile](../../Dockerfile) 在镜像构建中预编译资源；前端资源与 Rails 一起发布，没有独立 SPA 部署。
- [production.rb](../../config/environments/production.rb) 使用 Solid Queue，并连接名为 `queue` 的数据库配置；不能假设它与业务表在同一事务中提交。
- [deploy.yml](../../config/deploy.yml) 设置 `SOLID_QUEUE_IN_PUMA`；[puma.rb](../../config/puma.rb) 据此启动队列插件。
- [queue.yml](../../config/queue.yml) 当前 worker 监听所有队列，默认三线程，进程数由环境配置决定。
- [Procfile.dev](../../Procfile.dev) 只列 Rails 与 CSS watch，不能据此断言本地有生产式 worker。

这些是代码配置，不是生产健康检查；没有核实线上部署版本、数据库容量和实际 worker 状态。

### 第一版建议拓扑

```text
浏览器：现有 Archon 页面 + Turbo/Stimulus
                    |
             现有域名与代理
                    |
       Rails Web（页面、写操作、进度查询）
          |                         |
  业务 PostgreSQL              Solid Queue
  论文/作者/订阅/运行记录        后台同步任务
                                    |
                        全局限流 + 来源 API 客户端
                                    |
                         arXiv / OpenReview
```

前端、后端、Job 使用同一代码库和同一应用镜像，由现有 Kamal 发布流程交付；第一版不增加前端服务器、Python 服务、Redis 或浏览器采集容器，也不开放新公网端口。

为论文任务命名独立队列便于观察，但当前 worker 监听 `*`，队列命名本身不构成资源隔离。第一版需用低并发、分页拆分和有界任务控制负载；等待限流优先延后调度，避免长期占满现有 worker。若实测影响微信抓取或活动研究，再单独批准拆出 `bin/jobs` worker 角色，并明确队列分配；不是本轮默认部署变更。

### 发布与回退建议

1. 开发阶段先确认可丢弃的测试数据库，执行新增表迁移及离线验证，不修改既有 Article 数据。
2. 上线前核对队列数据库、提交后入队以及入队失败的补偿路径；业务记录已提交但入队失败必须可见且可重投。
3. 使用增量、兼容旧版本的迁移；明确执行迁移的步骤和权限，不假设现有发布脚本已经覆盖所有新表。
4. 新入口和周期同步设置开关，首次上线默认关闭周期同步，先做少量人工导入验收。
5. 开启少量会议/作者订阅，观察请求量、耗时、失败率和既有任务队列延迟，再扩大范围。
6. 回退时先关调度、停止新增任务并处理队列中尚未执行的新版 Job；不能让旧代码接收无法加载的 Job 类。保留新增表和数据，不用删表作为常规回退。

生产部署仍走仓库现有流程；本次文档变更不授权推送 main、运行生产迁移或部署。第一版只使用公开接口，若后续发现某来源需要凭据，再确认配置，不借用私人评审权限。

## 6. 验证与验收

### 必须证明的行为

| 场景 | 验收结果 |
|---|---|
| 同一 arXiv 论文的 abs/pdf/版本链接重复导入 | 一个来源身份，版本分别记录，无重复论文 |
| 一篇论文包含两位关注作者 | 一篇论文、多条署名与发现关系 |
| 同名作者、匿名作者 | 不自动错误合并，候选和缺失状态清楚 |
| OpenReview 录用、在审、撤稿和未知状态 | 按公开证据分别显示，未知不冒充成功或录用 |
| 一个来源超时、429 或返回错误内容 | 失败可审计，有界重试，不推进完整检查点 |
| 多页抓取中断或达到预算 | 标记待续，恢复不漏掉已记录的进度，不重复创建 |
| 多 worker 同时访问 arXiv | 全局串行和请求间隔有效，不因增加 worker 放大请求频率 |
| 取消关注、重投、晚到 Job | 不删除共享论文，不覆盖新任务状态 |
| 越权访问、恶意链接、摘要 HTML | 对象级授权、固定目标请求、转义输出；限制重定向和响应体大小 |
| 桌面与移动端导入、查看及重试 | 页面状态明确，后台执行不阻塞 HTTP 请求 |

实现时补 Minitest、外部接口 stub 和离线 E2E fixture；运行受影响测试、Zeitwerk、Rubocop，安全相关变更再做安全检查。浏览器 E2E 按仓库要求取得授权后运行。公开接口小样本联调与离线回归分别记录，不能互相替代。

现有可参考锚点：[Article](../../app/models/article.rb)、[Account](../../app/models/account.rb)、[ApplicationJob](../../app/jobs/application_job.rb)、[任务轮询](../../app/javascript/controllers/task_poller_controller.js)、[账号页面](../../app/views/accounts/index.html.erb)、[账号测试](../../test/models/account_test.rb)、[活动任务测试](../../test/models/event_research_task_test.rb)、[离线 E2E handlers](../../lib/e2e_mock/handlers.rb)。单篇导入代码和测试已在工作区，持续追踪测试待实现。

## 7. 实施检查点与实现细化

| 阶段 | 产出 | 进入下一阶段的条件 |
|---|---|---|
| 设计（方向已批准） | 本文及规格导航 | 已获用户同意继续开发 |
| 接口样本与实现清单 | 已支持链接样本、公开字段、模型/迁移/文件清单 | 样本读取结果明确，用户批准新增文件与数据设计 |
| 单篇导入 | 两种论文链接导入、详情、作者选择及离线测试 | 用户检查导入闭环 |
| 持续追踪 | 作者候选、年度会议订阅、增量同步与任务页面 | 用户检查身份和状态准确性 |
| 联调与上线准备 | 回归结果、运行说明、开关与回退方案 | 用户批准上线操作，不自动部署 |

已批准方向按本文推进：三个主要视图和统一导入入口、共享论文与个人订阅、具体年度会议、默认仅录用论文及每日同步、可选主题过滤。具体权限实现仍须验证，不能从共享元数据推导出允许修改他人订阅。

实现前继续细化模型约束和代码文件清单，定位 OpenReview 403；首批 CoRL/RSS 年份、历史回溯范围和作者种子样本在下一阶段提出具体建议。日期、频率与来源可用性应通过配置和测试明确，不将当前样本结果扩展为所有会议的承诺。

## 8. 官方资料与核查范围

以下资料已在需求调研中通过 Context7 或官方网页查阅；具体参数和公开能力仍需样本联调确认。

- [arXiv API 手册](https://info.arxiv.org/help/api/user-manual.html)：ID 查询、Atom 元数据、作者查询、分页和版本。
- [arXiv API 使用规则](https://info.arxiv.org/help/api/tou.html)：全局请求间隔、连接数及内容使用边界。
- [OpenReview API v2 客户端参考](https://github.com/openreview/openreview-py/blob/master/_autodocs/api-reference/client-v2.md)：公开数据读取与分页方法；Ruby 实现应核对 HTTP 契约，不把 Python 方法名当成 HTTP 路径。
- [OpenReview 数据读取指南](https://docs.openreview.net/how-to-guides/data-retrieval-and-modification/how-to-get-all-notes-for-submissions-reviews-rebuttals-etc)：venue、invitation、状态与公开回复。
- [CoRL 2026 作者指南](https://2026.corl.org/contributions/instruction-for-authors)：论文与评审公开规则。
- [RSS 2026 投稿说明](https://roboticsconference.org/2026/information/cfp/)：论文公开与评审不公开的边界。
- [Rails Active Job 指南](https://guides.rubyonrails.org/active_job_basics.html)：提交后入队与 Solid Queue 并发控制；队列并发限制不等于 HTTP 频率限制。

## 9. 持续追踪迭代计划（阶段 0/1 已批准）

本节记录用户提出的“读取新增论文 → 匹配关注作者 → 确认身份 → 保存入库”方案，细化前文的后续目标。用户已批准阶段 0/1；阶段 2 及以后仍按检查点评审后推进。

### 9.1 发现策略与“今天”的含义

采用两条互补链路，复用同一批来源记录和匹配逻辑：

1. **作者定向补查**：关注人数较少时先按已确认姓名变体、OpenReview profile ID 查询候选论文；首次回溯建议 90 天。关注作者不受具身主题分类硬过滤，避免漏掉跨学科成果。
2. **范围内增量发现**：按 arXiv 分类或明确的 OpenReview 年份/track 收集新记录，再与全部关注作者匹配。首批建议 arXiv `cs.RO`、`cs.LG`、`cs.AI`，以及经验证公开的 CoRL/RSS 年度主会；CVPR 等视觉方向在需要时补充。

“扫描全站今天所有论文”不作为初期默认。界面明确展示覆盖分类/会议、窗口、最后成功时间及完成程度；若以后确需 arXiv 全站日增量，优先评估官方 OAI-PMH，而非让每个作者订阅重复遍历全站。

| 时间/数量 | 定义与展示规则 |
|---|---|
| 首次提交、最新版本时间 | 保留上游字段；arXiv Atom `published` 对应首版，`updated` 对应返回版本，不充当公告时间 |
| 来源公开/公告时间 | 只有来源明确提供才保存；OpenReview `pdate`、`cdate`、`tcdate`、`tmdate` 分别保留语义，缺失不猜测 |
| 本地首次发现时间 | 本系统第一次观察到该来源 ID；“今日新增到库”默认按此统计，展示时区 Asia/Shanghai |
| 本轮扫描量 | 去重后的来源记录数，另记请求页数、重复数、失败数；不是源站全站新增总量 |
| 今日上架量 | 只有完成指定范围的公告/公开记录采集后才显示该口径；否则标注“本次发现”，不拿提交日期或 API totalResults 冒充 |
| 作者相关数量 | 分开显示候选、已确认、已排除；不同来源先分别计数，未经确认的跨来源重复不声称已经合并 |

arXiv 有公告日程和索引延迟，不能假设北京时间零点就能得到完整当天列表。API 的 `submittedDate` 用 GMT 范围；RSS/公告用于近期发现，不能承担完整历史回填。OAI 的 datestamp 表示元数据变化，不等于论文首次提交。OpenReview 没有本轮已验证的“全平台今日论文流”；仅扫描明确可读的投稿范围，评审和评论不计为论文。

建议每日同步一次，使用固定截止时间、最近 7 天重叠窗口，并每周补查最近 90 天候选和已知来源。窗口是初始可调参数，不保证涵盖所有延迟公开：OpenReview 录用/公开节点追加整届对账，定期重查已知论文及作者结果。不能只用创建时间下界，否则会漏掉很早创建、今天才公开的论文。

### 9.2 可选发现渠道与接入顺序

以下是 2026-10-19 文档调研结论，不代表这些接口均已联调。优先级是本项目建议。

| 渠道 | 可用方法 | 作用与限制 | 优先级 |
|---|---|---|---|
| arXiv API | `au:` 姓名检索、分类/提交日期检索、按更新时间排序、分页、ID 回查 | 适合预印本和新版本；姓名不是作者唯一 ID | 第一阶段主源 |
| arXiv RSS / OAI-PMH | 公告发现、按元数据 datestamp 增量采集及续页 | 同一来源的另一种采集方式；RSS 不作长期账本，OAI token 失效需重放窗口 | 分类规模扩大后 |
| OpenReview API v2 | 已确认 profile、投稿 invitation、venueid、公开 Note 分页 | 匿名、延迟公开、不同年度配置均需处理；403 保留失败，不能当零结果 | 第一阶段主源 |
| Semantic Scholar | 作者检索 → 人工核对 authorId → 作者论文列表；外部论文 ID 回源 | 适合跨来源补漏；作者聚类可能错，收录可能延迟；需核实 API key、配额和使用条款 | 后续首选补源之一 |
| OpenAlex | 作者/ORCID 定位、作者作品查询、出版日期和来源过滤 | 广覆盖、聚类需核对；当前官方文档将 updated-date 同步过滤列为付费能力，不能按免费无限增量设计 | 与 S2 做样本比较后选一个 |
| DBLP | 先核对作者 PID，再取该作者的结构化出版物记录 | 适合计算机会议和期刊、辅助消歧；不承诺最新预印本或完整摘要 | 会议补漏 |
| ORCID | 用户提供或由论文证据核验的 ORCID，按需读取公开 works | 主要用于身份佐证，记录可能不全；Public API 条款禁止持续轮询 registry，不设计为每日轮询主源 | 按需身份核验 |
| Crossref | DOI 元数据、作者/ORCID 检索、索引日期增量 | 补正式发表版本与 DOI；索引更新不等于新论文，作者字段取决于登记质量 | 发表信息补全 |
| 官方 proceedings / 作者主页 | 已知会议目录、机构或作者 publication 页，优先结构化导出与订阅 | PMLR、CVF 等逐站评估；不承诺任意链接自动适配。仅提取公开论文链接与元数据 | 有明确缺口后增加适配器 |

Google Scholar 暂不接入。上述渠道先解决作者身份和论文 ID 发现；能够回到 arXiv/OpenReview 的候选走已有导入链，只有 DOI 或其它来源的候选保留待处理证据，待批准相应适配器后落为该来源，不伪装成 arXiv/OpenReview 数据。PDF 全文下载继续不在本轮范围。

### 9.3 作者确认和入库规则

- 从种子论文署名进入“关注作者”，展示姓名变体、种子论文、可核对的机构/共同作者、公开 profile/ORCID；先由用户确认身份。Richard Sutton、Richard S. Sutton、R. S. Sutton 是待核对变体示例，不预先认定所有检索结果为同一人。
- 姓名规范化仅用于召回。精确同名、缩写、主题相近均只产生待确认候选；机构和共同作者用于展示理由，不直接升级为确定匹配。
- 已由用户核验的来源身份 ID 与公开论文作者 ID 一致时，可确认该订阅的归属关系；跨平台身份映射必须保存证据。匿名论文不绑定实名作者，作者公开后重新匹配。
- 候选的公开元数据可先幂等落库，同时创建 `pending` 匹配关系；作者“已确认论文”列表只显示确认项。确认/排除为当前用户操作，不替其他用户作身份判断，不因排除删除共享论文。
- 同来源按 `(provider, external_id)` 去重；arXiv 版本单独记录。跨来源通过明确 ID/DOI 等证据生成关联建议，标题相同不能直接合并。
- 同一论文命中多个作者只存一份来源记录，保留多个匹配关系；重复发现不清除用户确认/排除决定，证据变化记录为待复核。

### 9.4 前端、后端和部署边界

**前端**继续使用现有 Rails ERB/Turbo 页面。论文模块增加“关注作者”“待确认”“订阅会议”；论文详情提供“关注此作者”。作者页展示确认的身份、姓名变体、最新论文、候选理由、最近同步状态及手动同步/暂停。会议页选择明确年份与 track、公开投稿或已录用范围。运行页展示扫描范围、进度、失败项和续跑入口。没有完成扫描时不显示“已同步全部”。

**后端**保留独立论文领域，复用登录、PostgreSQL、Active Job、Solid Queue。把现有 `PaperImporter` 的请求、解析、持久化职责拆开，让列表已返回的完整元数据直接进入同一校验与写入路径，避免每条再发一次 API 请求。扩展时先解决当前“网络请求与 sleep 在数据库事务内”的连接占用，不能把这一方式直接放大为批量同步。

建议复用前文逻辑对象：作者身份/别名与来源映射、用户订阅、订阅匹配、同步运行及子项、来源版本。当前 `PaperAuthor` 同时承载未确认署名和部分来源身份，实施前必须明确迁移规则，不能按 normalized_name 批量合并。跨来源接入前需把署名及展示字段归属明确到来源，防止覆盖不同来源的作者顺序与摘要。

**执行流程**为：提交任务 → 按来源领取请求额度 → 获取一页 → 校验并写入短事务 → 记录候选/变更 → 保存续页位置 → 入队下一页。数据库协调全局请求间隔与有期限执行权，等待额度时重新调度；故障后恢复未完成页，旧执行者不能推进新运行检查点。只在整个固定范围成功扫完时提交完整检查点。

默认建议单页 100 条、单次运行最多 10 页，达到预算标记待续；初始范围和配额在接口样本阶段核定。429/5xx/超时采用有界退避并遵守 Retry-After；403、无效 venue 和解析失败分别显示。限制响应体、链接与分页总量，XML 禁止外部实体，保留安全的失败证据。

**部署**仍是同一 Rails 镜像中的页面与后台任务，不增独立前端、Python 或 Redis 服务。生产调度配置在验收后才启用；先手动跑 Richard Sutton 样本，再考虑每日任务。队列命名不等于资源隔离，需观察现有采集队列延迟。本文不授权生产迁移、推送或发布。

### 9.5 分阶段交付与文件范围

下面是拟议路径，不是已创建文件清单。每个阶段开始前确认最终新增文件与模型字段；不一次创建全部骨架。

| 阶段 | 交付内容 | 预计文件范围 | 检查点 |
|---|---|---|---|
| 0：收尾现有导入 | 补齐 schema、最终静态检查和离线浏览器验证；真实 OpenReview 公开样本验证；明确仍未验证项 | 现有 `app/services/paper_importer.rb`、相关模型/Job/视图/测试、`db/schema.rb`、既有 E2E 文件 | 展示结果后完成已有授权范围的本地提交，不 push |
| 1：接口与数据评审 | Sutton 姓名变体召回、profile 核验；验证 arXiv 分页/版本及 OpenReview 公开范围、时间字段与新 authorids 结构 | 只读样本及本文更新；批准后临时运行产物放 `tmp/` | 确认具体会议年份、范围、字段、请求预算和迁移清单 |
| 2：作者追踪闭环 | 种子作者关注、手动发现、候选确认/排除、幂等入库；先完成 arXiv，OpenReview 以阶段 1 连通为前提 | 拟增 `paper_subscription.rb`、`paper_subscription_match.rb`、`paper_sync_run.rb`、`paper_sync_item.rb`、`paper_source_revision.rb` 模型；身份映射独立表与否在阶段 1 确认；对应迁移、测试；`lib/arxiv_client.rb`、`lib/openreview_client.rb`、`app/services/paper_author_matcher.rb`、`app/jobs/paper_sync_job.rb`；作者/订阅控制器和对应视图 | Sutton 样本及同名反例验收，展示桌面/移动端流程，再创建阶段提交 |
| 3：每日增量与恢复 | 分类/作者增量、重叠窗口、分页续跑、限流、失败恢复、数量口径 | 扩展同步服务/Job；批准后添加到期分发 Job 与 `config/recurring.yml`，相关任务/并发测试 | 手动模拟多日、重复投递、崩溃和迟到数据；确认后启用本地调度 |
| 4：会议订阅 | 明确年度主会配置、公开能力、录用状态、具身主题标记 | 拟增 `paper_venue.rb` 与迁移、会议控制器/视图；复用订阅及同步运行 | 首批 CoRL/RSS 中实际可读的一届验收；其余逐届开放 |
| 5：补充来源 | S2/OpenAlex 小样本比较后选一个，按缺口增加 DBLP/Crossref/会议适配 | 独立来源客户端及对应离线测试，按批准范围扩展统一导入 | 展示增量收益、误匹配、延迟、API 配额/费用后再决定接入 |

阶段 2 不预先开放未实现的会议菜单；各阶段功能就绪后再展示入口。文件位置继续遵循现有 app/lib/test 分工，新增代码前单独列明对应视图与测试文件，取得确认后创建。

### 9.6 验收与待确认默认值

验收至少包括：已知 Sutton 种子被找到、姓名变体命中但同名反例不自动确认、匿名转公开后被重新检查、旧论文新版本不重复、跨来源同成果不误合并、重复 Job/跨进程限流/断点续页不破坏计数与检查点、失败不报零结果、用户不能修改他人订阅。数量面板能区分首版、版本更新、首次发现和候选确认。离线测试使用合成样本；少量公开接口联调单独记录来源时间、运行时间与实际结果。

阶段 0 和阶段 1 已获批准，结果见第 10 节；评审具体迁移和文件清单后再进入阶段 2。每日一次、首次回溯 90 天、7 天重叠窗口、每页 100 条/每次 10 页、首批三个 arXiv 分类、CoRL/RSS 明确年度主会，仍是后续同步功能的初始建议值，不表示定时任务已经启用。

### 9.7 本轮资料与证据边界

arXiv/OpenReview 使用 Context7 查阅官方文档；其他渠道检索官方说明。仅做能力调研，没有验证全部接口的可访问性或账号权限。OpenReview 检索结果混含 v1 示例，实施时仅采用经过 v2 HTTP 样本核对的参数，不把 SDK 方法直接当 HTTP 端点。

- [arXiv API 手册](https://info.arxiv.org/help/api/user-manual.html)：作者/日期查询、排序、分页、Atom 时间字段。
- [arXiv OAI-PMH](https://info.arxiv.org/help/oa/index.html)：元数据变化日期、公告后可用性和续页 token；[批量数据说明](https://info.arxiv.org/help/bulk_data.html)。
- [OpenReview v2 客户端参考](https://github.com/openreview/openreview-py/blob/master/_autodocs/api-reference/client-v2.md)：get_notes 的 content、invitation、分页和日期参数；[v2 模型](https://github.com/openreview/openreview-py/blob/master/_autodocs/api-reference/models-v2.md) 包含 authorids 新结构，需兼容对象与字符串，不能把对象直接转成作者名。
- [Semantic Scholar API](https://www.semanticscholar.org/product/api)：作者/论文图谱、API key 与配额；[许可](https://www.semanticscholar.org/product/api/license)。
- [OpenAlex API](https://help.openalex.org/api/)、[过滤与付费同步能力](https://help.openalex.org/api/filtering/)、[ORCID 映射](https://help.openalex.org/data/authors/orcid/)。
- [DBLP 作者出版物获取](https://dblp.org/faq/How+can+I+fetch+all+publications+of+one+specific+author)、[搜索 API](https://dblp.org/faq/13501473)。
- [ORCID 读取记录](https://info.orcid.org/documentation/api-tutorials/api-tutorial-read-data-on-a-record/)、[Public API 条款](https://info.orcid.org/public-client-terms-of-service/)：不将身份核验服务当持续轮询数据源。
- [Crossref REST API](https://www.crossref.org/documentation/retrieve-metadata/rest-api/)、[同步建议](https://www.crossref.org/documentation/retrieve-metadata/rest-api/tips-for-using-the-crossref-rest-api/)：索引变化与发表日期区别。

## 10. 阶段 0/1 结果与下一阶段评审（2026-10-19）

### 已验证与尚未验证

- 隔离 PostgreSQL 中完成新增六表迁移及 schema 导出；未连接生产数据库。服务/任务/控制器 21 项测试、105 个断言通过，13 个新增 Ruby 文件 Rubocop 通过，Zeitwerk 通过（保留既有 MCP eager-load 提示）。
- 离线浏览器用例通过：两种来源导入、403 部分失败、实时结果更新、详情、重复链接归到同一论文；检查 390px 移动端无横向溢出、侧栏收起，并查看截图。合成报文内置在既有 E2E handler 中，截图、视频和报告不提交。
- 最终代码重新真实导入 arXiv `2608.01475`、`2606.19357`，核对标题及完整作者顺序；前者 abs 和带版本 pdf 链接返回同一内部论文 ID。
- 安全扫描发现任务计数的动态 SQL 告警，已改为 Active Record 原子计数接口。全仓其余告警属于未修改文件，不将安全扫描描述为全仓无告警。
- OpenReview v2 已兼容字符串与 `fullname`/`username` 对象作者结构，按公开 profile ID 绑定，保留顺序；发表日期优先读取 `pdate`，不把创建时间当发表时间。两个来源的响应体限制为 2 MB。
- 尚未验证完整生产镜像构建、生产队列、多进程崩溃恢复。当前预览是 Docker 内独立源码副本，离线 mock 模式，不代表真实上游预览或生产发布。当前单篇导入串行锁仍会占用数据库连接，须在批量同步前重构。

### 接口样本结论

arXiv 三种姓名查询每次只读取前两条，结果总数是 API 当次报告的候选量，不是确认作品数，也不能相加：

| 查询 | totalResults | 观察 |
|---|---:|---|
| `au:"Richard Sutton"` | 78 | 最新两条为 `2608.01475v1`、`2606.19357v1` |
| `au:"Richard S Sutton"` | 70 | 最新两条与上一查询相同 |
| `au:"R S Sutton"` | 1 | 返回 `1607.05047v1`，说明不同变体的召回并不等价 |

`start=0/2,max_results=2` 两页分别返回上述两篇与 `2605.24238v1`、`2604.19033v1`，响应 startIndex 为 0/2，未出现跨页重复。请求间隔至少三秒。没有遍历全部候选，也没有把姓名匹配升级成身份确认。

OpenReview 已核实的真实年度 group 为 `robot-learning.org/CoRL/2025/Conference` 与 `roboticsfoundation.org/RSS/2025/Conference`；两者返回的 submission_id 分别是该 group 下的 `/-/Submission`。`CoRL.cc/2025/Conference` 返回 404，不能根据会议简称拼接 ID。

上述两届按真实 invitation 读取一条公开投稿、按单篇 ID 读取 note、以及 Richard/Sutton profile 查询，在当前环境均返回 HTTP 403；group 可读不能证明论文可读。尚未定位上游访问策略或网络原因，未核验 Sutton profile ID、录用论文范围或真实 authorids 新结构。OpenReview 成功路径仅有官方文档与合成报文依据，保留为待验收适配器，不开放会议订阅；不使用私人评审凭据绕过限制。

### 用户补充：首位与末位作者

默认从种子论文的首位和末位署名提取“建议关注作者”，单作者只产生一个候选；持久化仍保留全部作者及顺序。论文匹配记录同时保存命中位置与作者总数，界面可筛选“首位/末位”，完整作者视图保留中间位置命中供核对。这里只制定规则，关注和筛选功能属于阶段 2，尚未实现。

末位作者不自动标成通讯作者。通讯作者、共同第一作者、共同通讯作者只有上游明确提供才记录，缺失为未知；位置与主题均不能作为身份确认依据。原始作者列表缺失位置时不能因过滤空姓名而把第二位提升为第一位，需保留原始位置和缺失标记。

样本反例：`2608.01475` 的 Sutton 位于第 2/2 位，符合末位筛选；`2606.19357` 的 Sutton 位于第 4/5 位，末位是 John Carmack。后者若使用严格首末位过滤会被排除，所以筛选必须可解释，并保留完整署名，不能宣称已跟踪作者全部成果。

### 阶段 2 建议数据结构与文件清单（待确认，未创建）

先限定 arXiv 作者手动同步闭环；OpenReview 保留接口修复与复验，不因 403 扩大到会议批量抓取。建议沿用第 9 节路径，具体字段如下：

| 对象 | 拟议字段与不变量 |
|---|---|
| PaperSubscription | user_id、seed_authorship_id、display_name、name_variants JSON、verified_identifiers JSON（来源/ID/证据）、position_filter（默认首末位）、enabled；姓名规范化不构成全局身份唯一键 |
| PaperSubscriptionMatch | subscription_id、paper_source_id、原始 position、author_count、status（pending/confirmed/excluded）、evidence JSON、reviewed_at；订阅+来源+位置唯一，重跑不覆盖人工决定 |
| PaperSyncRun / Item | subscription_id、固定窗口/截止时间、status、计数、cursor/分页预算、lease_token/expires_at；Item 保存来源 ID、结果与错误，完成一页后写检查点，整轮未结束不报完成 |
| PaperSourceRevision | source_id、version/内容摘要、原始元数据、观测时间；来源+修订键唯一，不伪造历史 |
| PaperAuthorship 扩展 | 增加 paper_source_id，位置唯一约束从 paper 改到 source；回填仅在论文唯一来源可确定时执行，多来源歧义先报告 |

初版经用户核验的身份映射放订阅 JSON，权限属于用户，不通过同名合并全局 PaperAuthor；后续需要全局复用时再评审独立身份映射表。原有 PaperAuthor 继续保存导入署名，已有来源身份保留。

拟新增文件：`app/models/paper_subscription.rb`、`paper_subscription_match.rb`、`paper_sync_run.rb`、`paper_sync_item.rb`、`paper_source_revision.rb`；`app/services/paper_author_matcher.rb`、`paper_author_discovery.rb`；`lib/arxiv_client.rb`、`lib/openreview_client.rb`；`app/jobs/paper_sync_job.rb`；`app/controllers/paper_subscriptions_controller.rb`、`paper_subscription_matches_controller.rb`、`paper_sync_runs_controller.rb`；`app/views/paper_subscriptions/index.html.erb`、`show.html.erb`、`app/views/paper_sync_runs/show.html.erb`、`poll.turbo_stream.erb`；一份新增追踪表及署名归属迁移（实施时生成时间戳）。

对应测试拟增 `test/models/paper_subscription_test.rb`、`paper_subscription_match_test.rb`、`paper_sync_run_test.rb`、`paper_source_revision_test.rb`；`test/services/paper_author_matcher_test.rb`、`paper_author_discovery_test.rb`；`test/lib/arxiv_client_test.rb`、`openreview_client_test.rb`；`test/jobs/paper_sync_job_test.rb`；`test/controllers/paper_subscriptions_controller_test.rb`、`paper_subscription_matches_controller_test.rb`、`paper_sync_runs_controller_test.rb`。目录均沿用现有结构，仅新增两个对应视图目录。共享导入器、署名模型、routes、论文详情、用户关联及现有 E2E 文件同步修改。

阶段 2 验收包含：首/末/单作者、同名反例、中间位置命中可见且可筛选、匿名/空姓名不移位、共同作者角色未知、多来源署名不覆盖、确认/排除权限及重跑幂等。作者身份与文件清单待用户评审后执行，不在本次创建上述骨架。
