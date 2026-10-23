# 访问与内容交付

状态：当前实现基线（2026-10-16 核对）。

## 已实现能力

- Session、密码、Magic Link、邮箱确认和开发/测试环境开发者登录提供网页访问；生产环境不依赖固定默认管理员密码。
- `admin` 角色保护用户、标签、设置、分析、OAuth 应用和 MCP 调用记录等管理操作；普通用户可管理自己的资料、关注标签和 API Key。
- 标签、账号分组和用户关注标签支持网页管理，并影响列表筛选和 RSS 内容范围。
- RSS 提供全局、单账号、账号列表、标签、用户关注标签及网站监测变化等订阅入口。
- REST API 位于 `api/v1`，通过用户 `ApiKey` 鉴权，提供账号、文章、分组、标签和活动研究运行查询/操作。
- MCP 端点位于 `/mcp/endpoint`。资源服务器同时接受 Doorkeeper OAuth access token 和长期 API Key；OAuth 的工具调用按 `mcp:read` / `mcp:write` 检查，API Key 路径不执行 OAuth scope 检查，不能视为只读凭据。
- OAuth 发现、动态客户端注册、PKCE、RFC 8707 resource 受众校验和设备码流程由 OAuth 相关控制器与 `McpOauth` 协作完成。

## 安全边界

客户端提供的身份或资源参数不能单独授权写操作。OAuth 校验可用性、用户和受众；当前为兼容旧客户端允许空 resource，非空时必须匹配。API Key 使用独立验证路径。新增工具或路由必须同步授权清单和测试，不得把这两条凭据路径写成相同权限模型。真实凭据、含凭据的 URL 和非公开运行数据不进入文档或 fixture。

REST 中文章和研究运行是只读查询，分组支持 CRUD、账号支持更新和批量更新、标签支持创建；以路由和控制器为准，不推断所有资源都支持写入。设备码流程签发 ApiKey，不是带 scope 的 OAuth access token。

已有账号活跃度分析与仪表盘统计，不等于历史待确认的“活动分析看板”。已有文章搜索工具也不代表全文检索范围和产品验收已确定。

## 代码与测试入口

- [app/controllers/sessions_controller.rb](../../app/controllers/sessions_controller.rb)、[app/controllers/profiles_controller.rb](../../app/controllers/profiles_controller.rb)、[app/controllers/admin/](../../app/controllers/admin/)
- [app/controllers/api/v1/](../../app/controllers/api/v1/)、[app/controllers/rss_controller.rb](../../app/controllers/rss_controller.rb)
- [app/controllers/mcp_controller.rb](../../app/controllers/mcp_controller.rb)、[app/controllers/oauth/](../../app/controllers/oauth/)、[app/services/mcp_oauth.rb](../../app/services/mcp_oauth.rb)
- [docs/mcp.md](../mcp.md)、[test/services/mcp_oauth_test.rb](../../test/services/mcp_oauth_test.rb)、[test/integration/mcp_oauth_flow_test.rb](../../test/integration/mcp_oauth_flow_test.rb)、[test/mcp_server/](../../test/mcp_server/)

## 待确认

文章全文搜索、批量导出以及抓取完成/失败邮件通知的范围、权限和交付方式尚未确认；旧 README 的相关条目仅作为待确认事项保留。

## 企业邮箱自助注册（2026-10-23，内网免邮件验证）

用户确认取消注册邮件验证。当前流程为填写姓名、`@archon.tech` 邮箱和密码，注册成功后跳转密码登录；注册不发送邮件，也不把 email_confirmed_at 或 mailbox_verified 伪造成已验证。企业后缀只表示输入的域名，界面明确标注“未验证邮箱归属”，不证明人员在职或邮箱持有权。

- 新注册账号固定为普通用户；role、settings、email_confirmed_at 不接受客户端赋值。域名精确匹配，子域名和仿冒后缀拒绝。密码至少 12 字符、最多 72 字节，必须确认密码。
- 密码登录允许已确认的既有用户，或域名匹配的企业用户。之前已经注册但尚未验证的企业账号可用原密码登录，无需重新注册；不批量改变历史验证记录。其他未确认账号继续拒绝登录，Magic Link 的已确认邮箱要求保持不变。
- 删除本轮新增的注册验证路由、邮件方法、令牌和模板。既有管理员邀请与快捷登录不受影响，但仍依赖邮件服务；新注册与密码登录不依赖 SMTP。
- 注册保留 IP 限流（十分钟十次）和规范化邮箱限流（一分钟一次），生产必须使用共享缓存。重复注册不修改原密码或权限，并发冲突由数据库唯一约束兜底。
- 首期禁止已存在用户换邮箱，包括管理员更新；用户通知设置更新保留已有身份记录，不接受伪造验证标记。完整换绑和访问凭据撤销后续单独评审。
- 本方案依赖部署网络访问限制，不在代码中宣称已经限制内网。若仍存在公网地址或 Cloudflare 临时隧道，任何能访问的人都可填写企业邮箱注册；发布前必须核对实际网络入口。未创建默认管理员或授予首个注册者管理权限。

### 本地验证与文件范围

保留新增 RegistrationsController、sessions/register 页面及 registration_flow_test，复用现有 User、SessionsController、ProfilesController、routes、登录和个人资料页面。此前的验证页和两份确认邮件模板已移除，不增加数据库表。

免邮件流程和原有登录合计 22 项测试、172 条断言通过，覆盖不发邮件、注册后登录、旧待验证企业账号登录、权限参数、域名/密码校验、重复注册、限流及个人资料标记保护。没有运行真实并发压力测试；此前 40 项/263 断言属于含邮件验证的历史版本，不能作为当前版本的测试计数。

本地预览继续复用 archon-local 与 archon-local-db，不增加数据库容器。开发环境其他邮件仍写入 tmp/mails，不发送真实邮件。新注册流程无需读取该目录。本阶段仅交付代码，不执行服务器发布。

### 部署说明

GitHub 推送只保存代码，不代表服务器已运行新版本。已有服务器通常更新指定提交后构建镜像、注入生产配置、准备数据库、启动应用与队列并验收，不需要反复克隆。仓库 main 工作流仍包含旧部署设置和 Twitter 私有依赖，发布 News-agent 前必须核对目标和构建选项。服务器资料、密钥和 SMTP 凭据不进入 Git。

本次交付分支为 `codex/archon-branding-auth`，仓库为 `Lumen951/archon-crawler`；服务器须拉取该分支，不能只更新 main。先检查服务器工作区是否有本地配置改动，再获取远端并采用 fast-forward 更新；有冲突或分叉时停止核对，不强制覆盖。免邮件注册本身没有新增迁移，但若服务器落后于先前论文功能，仍需准备其迁移。镜像构建继续采用 `INSTALL_TWITTER_CLIENT=false` 才能跳过私有 Twitter 客户端；重建时保持已有数据库与 storage 挂载。上线后验收注册、密码登录和普通用户权限，不用首页 HTTP 200 替代业务验收。
