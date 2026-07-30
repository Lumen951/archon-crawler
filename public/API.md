# MP-Crawler API 文档

## 概述

MP-Crawler API 允许您查询帐号信息、管理帐号分组并查询跨平台（微信、小红书、Twitter）的文章。

## 认证

所有 API 端点都需要通过 Authorization header 中的 Bearer token 进行认证：

```
Authorization: Bearer <your_api_key>
```

API 密钥可以通过 Web 界面或 Rails 控制台创建。

## 基础 URL

```
https://your-domain.com/api/v1
```

---

## API 端点

### 1. GET /accounts

查询帐号信息。支持按名称或 ID 查找，如果数据库中不存在，会尝试通过外部 API 查找并创建。

当按名称搜索时，可能返回多个匹配结果。

#### 请求

```
GET /api/v1/accounts?source=wechat&name=北京大学
GET /api/v1/accounts?source=twitter&name=PKU1898
GET /api/v1/accounts?source=rednote&id=6229d4850000000021021d46
GET /api/v1/accounts?source=rednote&name=蔚来
```

**查询参数：**
- `source`（必填）：平台名称（`wechat`、`rednote`、`twitter`）
- `id`（可选）：帐号 ID（fakeid）
- `name`（可选）：帐号名称（至少需要 `id` 或 `name` 之一）

#### 响应示例

**成功（200 OK）- 按 ID 查找（返回单个帐号）：**
```json
{
  "source": "rednote",
  "accounts": [
    {
      "id": "6229d4850000000021021d46",
      "name": "北京大学",
      "round_head_img": "https://example.com/avatar.jpg"
    }
  ],
  "status": "found"
}
```

**成功（200 OK）- 按名称搜索（返回多个帐号）：**
```json
{
  "source": "rednote",
  "accounts": [
    {
      "id": "5663dbb17c5bb8369230f1b9",
      "name": "蔚来",
      "round_head_img": "https://sns-avatar-qc.xhscdn.com/avatar/..."
    },
    {
      "id": "657ff6960000000020031e74",
      "name": "NIO蔚来 童话",
      "round_head_img": "https://sns-avatar-qc.xhscdn.com/avatar/..."
    },
    {
      "id": "646f2972000000002a034f67",
      "name": "蔚来",
      "round_head_img": "https://sns-avatar-qc.xhscdn.com/avatar/..."
    }
  ],
  "status": "found"
}
```

**错误（404 Not Found）- 帐号未找到：**
```json
{
  "source": "wechat",
  "name": "不存在的帐号",
  "accounts": [],
  "status": "not_found",
  "error": "微信帐号未找到: 不存在的帐号"
}
```

**错误（400 Bad Request）- 缺少参数：**
```json
{
  "error": "source 不能为空（wechat/rednote/twitter）"
}
```

```json
{
  "error": "至少需要提供 id 或 name 参数"
}
```

**状态值说明：**
- `found`：帐号已存在于数据库中
- `created`：帐号已通过外部 API 查找并创建
- `not_found`：在平台上未找到帐号
- `error`：查找帐号时发生错误

**平台说明：**
- **微信**：支持按 `name` 搜索或按 `id` 查找
- **小红书**：支持按 `name` 搜索（通过 TikHub API）或按 `id` 查找
- **Twitter**：支持按 `name`（screen_name）搜索或按 `id` 查找

---

### 2. POST /groups

创建一个新的分组。

#### 请求

```json
{
  "ref_key": "pku",
  "accounts": [
    {"source": "wechat", "name": "北京大学"},
    {"source": "rednote", "name": "蔚来"},
    {"source": "twitter", "name": "PKU1898"}
  ]
}
```

**参数：**
- `ref_key`（必填）：分组的唯一标识符（字母、数字、下划线、连字符）
- `accounts`（必填）：帐号对象数组
  - `source`（必填）：平台名称（`wechat`、`rednote`、`twitter`）
  - `id`：帐号 ID（可选，精确匹配）
  - `name`：帐号名称（可选，用于搜索，可能返回多个匹配，使用第一个）

**说明：** 当按 `name` 搜索返回多个匹配时，系统自动使用第一个结果。响应中会包含 `multiple_matches` 字段提示匹配数量。

#### 响应示例

**成功（201 Created）- 所有帐号找到：**
```json
{
  "group": {
    "id": 1,
    "ref_key": "pku",
    "user_id": 1,
    "created_at": "2026-07-16T12:00:00.000+08:00"
  },
  "accounts": [
    {
      "source": "wechat",
      "id": "fakeid_wechat_123",
      "name": "北京大学",
      "status": "found"
    },
    {
      "source": "rednote",
      "id": "5663dbb17c5bb8369230f1b9",
      "name": "蔚来",
      "status": "found",
      "multiple_matches": 3,
      "hint": "找到 3 个匹配帐号，已使用第一个。可通过 id 精确指定。"
    },
    {
      "source": "twitter",
      "id": "1234567890",
      "name": "PKU1898",
      "status": "found"
    }
  ],
  "errors": []
}
```

**部分成功（201 Created）- 部分帐号未找到：**
```json
{
  "group": {
    "id": 2,
    "ref_key": "mixed",
    "user_id": 1,
    "created_at": "2026-07-16T12:00:00.000+08:00"
  },
  "accounts": [
    {
      "source": "wechat",
      "id": "fakeid_wechat_123",
      "name": "北京大学",
      "status": "found"
    }
  ],
  "errors": [
    {
      "index": 1,
      "source": "rednote",
      "id": "invalid_user_id",
      "name": null,
      "error": "小红书帐号未找到: invalid_user_id"
    },
    {
      "index": 2,
      "source": "twitter",
      "id": null,
      "name": "nonexistent_user",
      "error": "Twitter 帐号未找到: nonexistent_user"
    }
  ]
}
```

**错误（422 Unprocessable Entity）- ref_key 格式无效：**
```json
{
  "error": "ref_key 只能包含字母、数字、下划线和连字符"
}
```

**错误（422 Unprocessable Entity）- ref_key 重复：**
```json
{
  "error": "该用户已存在相同的 ref_key: pku"
}
```

**错误（401 Unauthorized）- 缺少或无效的 API 密钥：**
```json
{
  "error": "缺少 Authorization header"
}
```

```json
{
  "error": "无效的 API key"
}
```

---

### 3. PATCH /groups/{ref_key}

更新现有分组的帐号。

#### 请求

```json
{
  "accounts": [
    {"source": "wechat", "id": "fakeid_wechat_123"},
    {"source": "rednote", "name": "蔚来"},
    {"source": "twitter", "name": "PKU1898"}
  ]
}
```

**参数：**
- `ref_key`（路径参数）：分组标识符
- `accounts`（必填）：新的帐号对象数组（替换现有帐号）

#### 响应示例

**成功（200 OK）- 所有帐号找到：**
```json
{
  "group": {
    "id": 1,
    "ref_key": "pku",
    "user_id": 1,
    "created_at": "2026-07-16T12:00:00.000+08:00"
  },
  "accounts": [
    {
      "source": "wechat",
      "id": "fakeid_wechat_123",
      "name": "北京大学"
    },
    {
      "source": "rednote",
      "id": "6229d4850000000021021d46",
      "name": "北京大学"
    },
    {
      "source": "twitter",
      "id": "1234567890",
      "name": "PKU1898"
    }
  ],
  "errors": []
}
```

**部分成功（200 OK）- 部分帐号未找到：**
```json
{
  "group": {
    "id": 1,
    "ref_key": "pku",
    "user_id": 1,
    "created_at": "2026-07-16T12:00:00.000+08:00"
  },
  "accounts": [
    {
      "source": "wechat",
      "id": "fakeid_wechat_123",
      "name": "北京大学"
    }
  ],
  "errors": [
    {
      "index": 1,
      "source": "rednote",
      "id": "invalid_user_id",
      "name": null,
      "error": "小红书帐号未找到: invalid_user_id"
    }
  ]
}
```

**错误（404 Not Found）- 分组未找到：**
```json
{
  "error": "分组未找到: nonexistent"
}
```

**错误（401 Unauthorized）- 缺少或无效的 API 密钥：**
```json
{
  "error": "缺少 Authorization header"
}
```

---

### 4. GET /articles

查询分组中的文章，支持分页和筛选。

#### 请求

```
GET /api/v1/articles?group_ref_keys[]=pku&group_ref_keys[]=tsinghua&range[]=2026-07-01&range[]=2026-07-15&source=wechat&page=1&per_page=25
```

**查询参数：**
- `group_ref_keys[]`（必填）：要查询的分组 ref_key 数组
- `range[]`（必填）：日期范围 [开始日期, 结束日期]，格式为 YYYY-MM-DD
- `source`（可选）：按平台筛选（`wechat`、`rednote`、`twitter`）
- `page`（可选）：页码（默认：1）
- `per_page`（可选）：每页数量（默认：25，最大：100）

#### 响应示例

**成功（200 OK）- 有文章：**
```json
{
  "articles": [
    {
      "id": 1,
      "title": "北京大学2026年招生简章",
      "url": "https://example.com/article1",
      "digest": "北京大学2026年招生简章正式发布，本文详细介绍...",
      "content": "# 北京大学2026年招生简章\n\n...",
      "published_at": "2026-07-10T10:00:00.000+08:00",
      "group_ref_key": "pku",
      "account": {
        "id": 1,
        "id": "fakeid_wechat_123",
        "source": "wechat",
        "name": "北京大学"
      }
    },
    {
      "id": 2,
      "title": "北京大学新生入学指南",
      "url": "https://example.com/article2",
      "digest": "新生入学指南，包含报到流程...",
      "content": "# 新生入学指南\n\n...",
      "published_at": "2026-07-08T15:30:00.000+08:00",
      "group_ref_key": "pku",
      "account": {
        "id": 2,
        "id": "6229d4850000000021021d46",
        "source": "rednote",
        "name": "北京大学"
      }
    }
  ],
  "pagination": {
    "page": 1,
    "per_page": 25,
    "total_count": 2,
    "total_pages": 1
  }
}
```

**成功（200 OK）- 无文章：**
```json
{
  "articles": [],
  "pagination": {
    "page": 1,
    "per_page": 25,
    "total_count": 0,
    "total_pages": 0
  }
}
```

**成功（200 OK）- 使用平台筛选：**
```json
{
  "articles": [
    {
      "id": 1,
      "title": "北京大学2026年招生简章",
      "url": "https://example.com/article1",
      "digest": "北京大学2026年招生简章正式发布...",
      "content": "# 北京大学2026年招生简章\n\n...",
      "published_at": "2026-07-10T10:00:00.000+08:00",
      "group_ref_key": "pku",
      "account": {
        "id": 1,
        "id": "fakeid_wechat_123",
        "source": "wechat",
        "name": "北京大学"
      }
    }
  ],
  "pagination": {
    "page": 1,
    "per_page": 25,
    "total_count": 1,
    "total_pages": 1
  }
}
```

**错误（400 Bad Request）- 缺少 group_ref_keys：**
```json
{
  "error": "group_ref_keys 不能为空"
}
```

**错误（400 Bad Request）- 日期范围无效：**
```json
{
  "error": "range 必须包含两个日期 [start_date, end_date]"
}
```

```json
{
  "error": "日期格式无效，请使用 YYYY-MM-DD 格式"
}
```

**错误（400 Bad Request）- 平台筛选无效：**
```json
{
  "error": "不支持的平台: invalid_platform"
}
```

**错误（404 Not Found）- 未找到分组：**
```json
{
  "error": "未找到指定的分组"
}
```

**错误（401 Unauthorized）- 缺少或无效的 API 密钥：**
```json
{
  "error": "缺少 Authorization header"
}
```

---

## 文章内容字段说明

API 返回的文章内容经过清洗处理，提供更高质量的数据：

| 字段 | 说明 | 数据来源 |
|------|------|----------|
| `digest` | 文章摘要（清洗后） | 优先使用 API 提供的摘要，其次使用清洗后的 markdown 内容截断 |
| `content` | 文章正文（清洗后） | 原始 markdown 内移除 CSS/JS 污染 |

### 各平台内容处理

| 平台 | digest 来源 | content 清洗 |
|------|-------------|--------------|
| **微信** | API 返回的 `digest` 字段 | 移除开头的 CSS 样式块 |
| **小红书** | 笔记描述 + 标签 | 使用 `note_card.desc`（去除重复标签） |
| **Twitter** | 推文文本 + 互动数据 | 原始推文文本 |

### 互动数据（engagement）

各平台的互动数据包含在 digest 中（格式化为 emoji 前缀）：
- **小红书**：❤ 点赞 | 💬 评论 | 🔗 分享 | ⭐ 收藏
- **Twitter**：❤ 点赞 | 🔁 转推 | 💬 回复 | 👁 浏览量

---

## 帐号状态值

创建或更新分组时，帐号可能具有以下状态：

- `found`：帐号已存在于数据库中
- `created`：帐号已通过 API 响应创建
- `not_found`：在平台上未找到帐号
- `error`：解析帐号时发生错误

## 平台说明

### 微信（wechat）
- 可以通过 `name` 搜索或通过 `id`（fakeid）查找
- 搜索使用微信官方 API
- 帐号类型为 `WechatAccount`

### 小红书（rednote）
- 可以通过 `name` 搜索（通过 TikHub API）或通过 `id` 查找
- 按 `id` 查找时使用 `/xhs/user_detail` API 验证用户是否存在
- 按 `name` 搜索时使用 TikHub 搜索用户 API，可能返回多个结果
- 帐号类型为 `RednoteAccount`

### Twitter
- 可以通过 `name`（screen_name）搜索或通过 `id`（rest_id）查找
- 搜索使用 Twitter API 客户端
- 帐号类型为 `TwitterAccount`

## 速率限制

API 端点根据您的 API 密钥配置进行速率限制。默认限制为每分钟 100 个请求。

## 错误代码

| 状态码 | 说明 |
|--------|------|
| 200 | 成功 |
| 201 | 已创建（POST 请求） |
| 400 | 错误请求 - 参数无效 |
| 401 | 未授权 - 缺少或无效的 API 密钥 |
| 404 | 未找到 - 资源不存在 |
| 422 | 无法处理 - 验证错误 |
| 500 | 服务器内部错误 |

## 示例

### 查询帐号（按名称 - 返回多个结果）
```bash
curl "https://your-domain.com/api/v1/accounts?source=rednote&name=蔚来" \
  -H "Authorization: Bearer YOUR_API_KEY"
```

### 查询帐号（按 ID - 返回单个结果）
```bash
curl "https://your-domain.com/api/v1/accounts?source=rednote&id=6229d4850000000021021d46" \
  -H "Authorization: Bearer YOUR_API_KEY"
```

### 通过名称创建分组（包含多个平台）
```bash
curl -X POST "https://your-domain.com/api/v1/groups" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "ref_key": "pku",
    "accounts": [
      {"source": "wechat", "name": "北京大学"},
      {"source": "rednote", "name": "蔚来"},
      {"source": "twitter", "name": "PKU1898"}
    ]
  }'
```

### 通过 ID 创建分组（精确匹配）
```bash
curl -X POST "https://your-domain.com/api/v1/groups" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "ref_key": "pku-exact",
    "accounts": [
      {"source": "rednote", "id": "6229d4850000000021021d46"}
    ]
  }'
```

### 更新分组
```bash
curl -X PATCH "https://your-domain.com/api/v1/groups/pku" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "accounts": [
      {"source": "wechat", "id": "fakeid_wechat_123"},
      {"source": "rednote", "name": "蔚来"},
      {"source": "twitter", "name": "PKU1898"}
    ]
  }'
```

### 查询多个分组的文章
```bash
curl -G "https://your-domain.com/api/v1/articles" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  --data-urlencode "group_ref_keys[]=pku" \
  --data-urlencode "group_ref_keys[]=tsinghua" \
  --data-urlencode "range[]=2026-07-01" \
  --data-urlencode "range[]=2026-07-15" \
  --data-urlencode "page=1" \
  --data-urlencode "per_page=25"
```

### 使用平台筛选查询文章
```bash
curl -G "https://your-domain.com/api/v1/articles" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  --data-urlencode "group_ref_keys[]=pku" \
  --data-urlencode "range[]=2026-07-01" \
  --data-urlencode "range[]=2026-07-15" \
  --data-urlencode "source=wechat"
```
