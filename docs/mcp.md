# MP-Crawler MCP Server

本项目提供 [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) 服务，让 AI 助手（Claude Desktop、Cursor、VS Code Copilot 等）可以直接查询和管理公众号/小红书/Twitter 账号。

## 端点

```
POST/GET/DELETE https://<your-host>/mcp/endpoint
```

认证有两条路：**OAuth 2.1 授权**（客户端自行发现并引导用户完成，推荐）或 `Authorization: Bearer <token>` header。

---

## 快速连接

### Claude Code / Codex（OAuth，无需手动配置 token）

服务端实现了 MCP 授权规范（2026-07-28），客户端会自动发现并拉起浏览器授权：

```bash
# Claude Code
claude mcp add --transport http mp-crawler https://<your-host>/mcp/endpoint
# 然后在会话中输入 /mcp，选择 Authenticate，浏览器会自动打开授权页

# Codex
codex mcp add mp-crawler --url https://<your-host>/mcp/endpoint
codex mcp login mp-crawler
```

首次授权时会看到同意页，列出该客户端将获得的权限。授权后 access token 2 小时过期，客户端自动用
refresh token 续期，无需再次操作。

### Claude Desktop

编辑 `~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "mp-crawler": {
      "url": "https://<your-host>/mcp/endpoint",
      "headers": {
        "Authorization": "Bearer YOUR_API_KEY"
      }
    }
  }
}
```

### Cursor

在项目根目录创建 `.cursor/mcp.json`：

```json
{
  "mcpServers": {
    "mp-crawler": {
      "url": "https://<your-host>/mcp/endpoint",
      "headers": {
        "Authorization": "Bearer YOUR_API_KEY"
      }
    }
  }
}
```

### VS Code / GitHub Copilot

在项目根目录创建 `.vscode/mcp.json`：

```json
{
  "servers": {
    "mp-crawler": {
      "url": "https://<your-host>/mcp/endpoint",
      "type": "http",
      "headers": {
        "Authorization": "Bearer YOUR_API_KEY"
      }
    }
  }
}
```

---

## 认证方式

### 方式一：OAuth 2.1 授权码流程（推荐）

支持 MCP 授权规范的客户端（Claude Code、Codex 等）会自己走完下面这条链路，**你不需要做任何配置**，
只要在客户端里添加 URL 然后按提示授权即可：

```
1. Client → POST /mcp/endpoint（无 token）
2. Server → 401 + WWW-Authenticate: Bearer resource_metadata="...", scope="mcp:read mcp:write"
3. Client → GET /.well-known/oauth-protected-resource/mcp/endpoint   (RFC 9728)
4. Client → GET /.well-known/oauth-authorization-server              (RFC 8414)
5. Client → POST /oauth/register 动态注册自己                        (RFC 7591)
6. Client → 浏览器打开 /oauth/authorize（PKCE S256 + resource 参数）
7. Client → POST /oauth/token 换 access_token + refresh_token
8. Client → 带 Bearer 重试 /mcp/endpoint
```

**权限范围**：

| Scope | 覆盖的工具 |
|-------|-----------|
| `mcp:read` | `list_accounts`、`get_account`、`list_articles`、`list_tags`、`get_activity_stats`、`weread_accounts` |
| `mcp:write` | `update_accounts`、`batch_update_accounts_by_filter`、`weread_login_start`、`weread_login_status` |

只拿到 `mcp:read` 的客户端调用写工具会收到 `403 insufficient_scope`，客户端据此发起提权授权。

**如果客户端不支持动态注册**：部分客户端要求预先注册的 client_id。目前只能通过 `rails console`
手工建一个（`Doorkeeper::Application.create!(name:, redirect_uri:, scopes: "mcp:read mcp:write", confidential: false)`），
再把 `uid` 作为 client_id 配给客户端。

### 方式二：Bearer Token

在 `/profile` 或 `/mcp` 页面创建 API Key，获取 token 后配置到 MCP 客户端。适合脚本、CI 或不支持
OAuth 的客户端。注意这类 token **不会过期**，请妥善保管并在不再需要时撤销。

### 方式三：Device Code 授权

适用于无法打开浏览器的环境。授权后签发的同样是长期 API Key。

**流程**：

1. MCP 客户端请求 device code：
```bash
curl -X POST https://<your-host>/oauth/device \
  -d "client_id=my-mcp-client"
```

2. 响应中获取 `user_code` 和 `verification_uri`：
```json
{
  "device_code": "abc123...",
  "user_code": "ABCD-1234",
  "verification_uri": "https://<your-host>/oauth/device/authorize",
  "verification_uri_complete": "https://<your-host>/oauth/device/authorize?code=ABCD-1234",
  "expires_in": 900,
  "interval": 5
}
```

3. 用户在浏览器中访问 `verification_uri_complete`，登录并授权

4. 客户端轮询 token 端点：
```bash
curl -X POST https://<your-host>/oauth/token \
  -d "grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code=abc123..."
```

5. 用户授权后获取 access_token：
```json
{
  "access_token": "your-api-key-token",
  "token_type": "Bearer"
}
```

---

## 可用 Tools

### `list_accounts` — 列出账号

列出所有账号，支持按平台、状态、活跃度、标签、关键词过滤和分页。

**Parameters:**
| Name | Required | Description |
|------|----------|-------------|
| `platform` | optional | `wechat` / `rednote` / `twitter` |
| `status` | optional | `active` / `inactive` |
| `activity_level` | optional | `active` / `slow` / `dormant` / `dead` / `never` / `uncrawled` |
| `tag_id` | optional | 按标签 ID 过滤 |
| `keyword` | optional | 按账号名称搜索 |
| `page` | optional | 页码（默认 1） |
| `per_page` | optional | 每页数量（默认 25，最大 100） |

**Returns:** 账号列表，包含 id、nickname、platform、status、activity_level、activity_score、total_articles、articles_last_7_days、articles_last_30_days、last_published_at、tags 等字段。

---

### `get_account` — 获取账号详情

获取单个账号的详细信息，包含活动统计、标签、最近文章摘要。

**Parameters:**
| Name | Required | Description |
|------|----------|-------------|
| `account_id` | ✅ | 账号 ID |

**Returns:** 账号完整信息，包含最近 10 篇文章的 id、title、url、published_at、digest。

---

### `list_articles` — 查询文章

查询某账号的文章列表，支持日期范围过滤和分页。

**Parameters:**
| Name | Required | Description |
|------|----------|-------------|
| `account_id` | ✅ | 账号 ID |
| `start_date` | optional | 起始日期（YYYY-MM-DD） |
| `end_date` | optional | 结束日期（YYYY-MM-DD） |
| `page` | optional | 页码（默认 1） |
| `per_page` | optional | 每页数量（默认 25，最大 100） |

**Returns:** 文章列表，包含 id、title、url、published_at、digest、content（完整正文 Markdown；无正文时为 null）。

---

### `update_accounts` — 批量操作账号

批量启用/停用账号、添加/移除标签。

**Parameters:**
| Name | Required | Description |
|------|----------|-------------|
| `account_ids` | ✅ | 要操作的账号 ID 列表 |
| `status` | optional | `active` / `inactive` |
| `add_tag_ids` | optional | 要添加的标签 ID 列表 |
| `remove_tag_ids` | optional | 要移除的标签 ID 列表 |
| `add_tag_names` | optional | 要添加的标签名称（不存在则自动创建） |

**Returns:** 操作结果统计。

---

### `batch_update_accounts_by_filter` — 按条件批量操作账号

按过滤条件批量更新账号（打标签/改状态），无需先列出再操作，直接在服务端完成。

**Parameters:**
| Name | Required | Description |
|------|----------|-------------|
| `filter` | optional | 过滤条件对象（`platform` / `status` / `activity_level` / `tag_id` / `keyword`），为空则匹配所有账号 |
| `status` | optional | `active` / `inactive` |
| `add_tag_ids` | optional | 要添加的标签 ID 列表 |
| `remove_tag_ids` | optional | 要移除的标签 ID 列表 |
| `add_tag_names` | optional | 要添加的标签名称（不存在则自动创建） |
| `dry_run` | optional | 仅返回匹配数量，不实际执行（默认 false） |

**Returns:** 匹配/更新的账号数量；`dry_run: true` 时只返回匹配数量。

---

### `list_tags` — 列出标签

列出所有标签及其关联账号数量。

**Parameters:**
| Name | Required | Description |
|------|----------|-------------|
| `keyword` | optional | 按标签名称搜索 |

**Returns:** 标签列表，包含 id、name、color、description、accounts_count。

---

### `get_activity_stats` — 活跃度统计

获取各平台账号活跃度统计概览。

**Parameters:** 无

**Returns:** 各平台的 active/slow/dormant/dead/never/uncrawled 数量分布，以及汇总统计。

---

### `weread_login_start` — 发起微信读书登录

发起微信读书（WeRead）登录，返回**终端可显示的 ASCII/Unicode 二维码**（非 PNG 图片），供 CLI 工具直接打印给用户扫码。

**Parameters:**
| Name | Required | Description |
|------|----------|-------------|
| `invert` | optional | 浅色背景终端设为 true（默认 false，适配深色终端） |
| `style` | optional | `half_block`（默认，紧凑半块字符）/ `full_block`（每模块两字符） |

**Returns:** 三段内容——① 裸二维码字符画（需逐字原样输出）；② 给 assistant 的输出指令；③ JSON 元数据（含 `uuid`、`scan_url`、`width`、`height`、`expires_in_seconds`）。

---

### `weread_login_status` — 查询登录结果

服务端短轮询微信读书扫码状态，登录成功后自动把账号写入转发账号池。

**Parameters:**
| Name | Required | Description |
|------|----------|-------------|
| `uuid` | optional | 登录会话 ID；不传则使用最近一次由本 API Key 发起的会话 |
| `wait_seconds` | optional | 服务端最多轮询秒数（默认 20，最大 55） |

**Returns:** `status` 为 `success`（含 `username`/`vid`/`total_accounts`）、`scanned`、`waiting` 或 `expired`。

---

### `weread_accounts` — 列出转发账号池

列出微信读书转发账号池（vid、昵称、状态、当日限流情况），**不含 token 凭据**。

**Parameters:** 无

**Returns:** `total` / `enabled` / `blocked_today` / `accounts`（每项含 `vid`、`name`、`status`、`status_code`、`blocked_today`）。

---

## 典型使用场景

### 场景一：分析并清理低价值账号

```
Agent: 先调用 get_activity_stats 了解整体情况
Agent: 调用 list_accounts(activity_level="never") 查看从未发布的账号
Agent: 调用 list_accounts(activity_level="dead") 查看已失活的账号
Agent: 对每个账号调用 get_account 查看详情
Agent: 调用 update_accounts(account_ids=[...], status="inactive") 停用低价值账号
```

### 场景二：按内容分类打标签

```
Agent: 调用 list_accounts(platform="wechat") 列出所有公众号
Agent: 对每个账号调用 get_account 获取最近文章
Agent: 根据文章内容分析账号主题
Agent: 调用 update_accounts(account_ids=[...], add_tag_names=["AI", "教育"]) 打标签
```

### 场景三：按活跃度分层管理

```
Agent: 调用 get_activity_stats 获取统计
Agent: 调用 list_accounts(activity_level="active") 查看活跃账号
Agent: 调用 list_accounts(activity_level="dormant") 查看停更账号
Agent: 批量操作：活跃账号打标签，停更账号标记为 inactive
```

---

## 实现说明

- **认证**: Bearer Token 存储为 SHA256 摘要（`ApiKey` 模型）；Device Code 流程符合 RFC 8628
- **Transport**: Stateless HTTP (StreamableHTTP transport)，无需持久 SSE 会话
- **MCP gem**: `mcp` gem v0.25.0 (Ruby)
- **调用日志**: 每次 tool call 记录到 `mcp_tool_calls` 表（user、tool_name、arguments、status、duration、ip）
