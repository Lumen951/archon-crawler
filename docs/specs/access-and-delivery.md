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
