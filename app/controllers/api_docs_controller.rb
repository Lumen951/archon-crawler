class ApiDocsController < ApplicationController
  allow_unauthenticated_access
  layout false

  def show
    @openapi_url = api_docs_openapi_url
  end

  def openapi
    spec = {
      openapi: "3.1.0",
      info: {
        title: "MP-Crawler API",
        version: "1.0.0",
        description: "微信公众号、小红书和 Twitter 文章爬虫 & RSS 订阅服务 API"
      },
      servers: [
        { url: request.base_url, description: "Current" }
      ],
      paths: account_paths.merge(article_paths).merge(tag_paths).merge(group_paths).merge(event_research_run_paths),
      components: {
        securitySchemes: {
          BearerAuth: {
            type: "http",
            scheme: "bearer",
            description: "在 /profile 页面创建 API Key"
          }
        },
        schemas: account_schema.merge(article_schema).merge(tag_schema).merge(group_schema).merge(event_research_run_schema).merge(pagination_schema)
      }
    }

    render json: spec
  end

  private

  def account_paths
    {
      "/api/v1/accounts" => {
        get: {
          summary: "列出账号",
          description: "列出所有账号，支持按平台、状态、活跃度、标签、关键词过滤",
          tags: ["Accounts"],
          security: [{ BearerAuth: [] }],
          parameters: [
            { name: "platform", in: "query", required: false, schema: { type: "string", enum: %w[wechat rednote twitter website] }, description: "可选：按平台过滤" },
            { name: "status", in: "query", required: false, schema: { type: "string", enum: %w[active inactive] }, description: "可选：按状态过滤" },
            { name: "activity_level", in: "query", required: false, schema: { type: "string", enum: %w[active slow dormant dead never uncrawled] }, description: "可选：按活跃度过滤" },
            { name: "tag_id", in: "query", required: false, schema: { type: "integer" }, description: "可选：按标签 ID 过滤" },
            { name: "keyword", in: "query", required: false, schema: { type: "string" }, description: "可选：按账号名称搜索" },
            { name: "page", in: "query", required: false, schema: { type: "integer", default: 1, minimum: 1 }, description: "可选：页码，默认 1" },
            { name: "per_page", in: "query", required: false, schema: { type: "integer", default: 25, minimum: 1, maximum: 100 }, description: "可选：每页数量，默认 25，最大 100" },
          ],
          responses: {
            "200" => {
              description: "成功",
              content: { "application/json" => { schema: {
                type: "object",
                properties: {
                  accounts: { type: "array", items: { "$ref" => "#/components/schemas/Account" } },
                  pagination: { "$ref" => "#/components/schemas/Pagination" }
                }
              }}}
            }
          }
        }
      },
      "/api/v1/accounts/{id}" => {
        get: {
          summary: "获取账号详情",
          tags: ["Accounts"],
          security: [{ BearerAuth: [] }],
          parameters: [ { name: "id", in: "path", required: true, schema: { type: "integer" } } ],
          responses: { "200" => { description: "成功" } }
        },
        patch: {
          summary: "更新账号",
          tags: ["Accounts"],
          security: [{ BearerAuth: [] }],
          parameters: [ { name: "id", in: "path", required: true, schema: { type: "integer" } } ],
          requestBody: {
            content: { "application/json" => { schema: {
              type: "object",
              properties: {
                status: { type: "string", enum: %w[active inactive] },
                tag_ids: { type: "array", items: { type: "integer" } },
                add_tag_ids: { type: "array", items: { type: "integer" } },
                remove_tag_ids: { type: "array", items: { type: "integer" } },
              }
            }}}
          },
          responses: { "200" => { description: "成功" } }
        }
      },
      "/api/v1/accounts/bulk_update" => {
        post: {
          summary: "批量更新账号",
          tags: ["Accounts"],
          security: [{ BearerAuth: [] }],
          requestBody: {
            content: { "application/json" => { schema: {
              type: "object",
              required: ["ids"],
              properties: {
                ids: { type: "array", items: { type: "integer" } },
                status: { type: "string", enum: %w[active inactive] },
                add_tag_ids: { type: "array", items: { type: "integer" } },
                remove_tag_ids: { type: "array", items: { type: "integer" } },
              }
            }}}
          },
          responses: { "200" => { description: "成功" } }
        }
      },
      "/api/v1/accounts/lookup" => {
        get: {
          summary: "查找账号（兼容旧接口）",
          tags: ["Accounts"],
          security: [{ BearerAuth: [] }],
          parameters: [
            { name: "source", in: "query", required: true, schema: { type: "string", enum: %w[wechat rednote twitter] } },
            { name: "id", in: "query", required: false, schema: { type: "string" }, description: "可选：按平台账号 ID 精确查询" },
            { name: "name", in: "query", required: false, schema: { type: "string" }, description: "可选：按账号名称查询" },
          ],
          responses: { "200" => { description: "成功" } }
        }
      }
    }
  end

  def article_paths
    {
      "/api/v1/articles" => {
        get: {
          summary: "查询文章",
          tags: ["Articles"],
          security: [{ BearerAuth: [] }],
          parameters: [
            { name: "account_id", in: "query", required: false, schema: { type: "integer" }, description: "账号模式：按单个账号查询；可搭配 keyword、start_date、end_date" },
            { name: "keyword", in: "query", required: false, schema: { type: "string" }, description: "全局搜索模式必填：未传 account_id 或 group_ref_keys 时按标题、摘要和正文全局模糊搜索；多个词用空格分隔（AND 语义）" },
            { name: "platform", in: "query", required: false, schema: { type: "string", enum: %w[wechat rednote twitter website] }, description: "全局搜索模式可选：按平台过滤" },
            { name: "start_date", in: "query", required: false, schema: { type: "string", format: "date" }, description: "账号或全局搜索模式可选；分组模式必填：起始日期（YYYY-MM-DD）" },
            { name: "end_date", in: "query", required: false, schema: { type: "string", format: "date" }, description: "账号或全局搜索模式可选；分组模式必填：结束日期（YYYY-MM-DD）" },
            { name: "group_ref_keys[]", in: "query", required: false, schema: { type: "array", items: { type: "string" } }, description: "分组模式必填；未传 account_id 或 keyword 时至少传一个分组 ref_key" },
            { name: "page", in: "query", required: false, schema: { type: "integer", default: 1, minimum: 1 }, description: "可选：页码，默认 1" },
            { name: "per_page", in: "query", required: false, schema: { type: "integer", default: 25, minimum: 1, maximum: 100 }, description: "可选：每页数量，默认 25，最大 100" },
          ],
          responses: { "200" => { description: "成功" } }
        }
      }
    }
  end

  def tag_paths
    {
      "/api/v1/tags" => {
        get: { summary: "列出标签", tags: ["Tags"], security: [{ BearerAuth: [] }], responses: { "200" => { description: "成功" } } },
        post: {
          summary: "创建标签", tags: ["Tags"], security: [{ BearerAuth: [] }],
          requestBody: { content: { "application/json" => { schema: { type: "object", required: ["name"], properties: { name: { type: "string" } } } } } },
          responses: { "201" => { description: "创建成功" } }
        }
      },
      "/api/v1/tags/{id}" => {
        get: { summary: "标签详情", tags: ["Tags"], security: [{ BearerAuth: [] }], parameters: [ { name: "id", in: "path", required: true, schema: { type: "integer" } } ], responses: { "200" => { description: "成功" } } }
      }
    }
  end

  def group_paths
    {
      "/api/v1/groups" => {
        get: { summary: "列出分组", tags: ["Groups"], security: [{ BearerAuth: [] }], responses: { "200" => { description: "成功" } } },
        post: { summary: "创建分组", tags: ["Groups"], security: [{ BearerAuth: [] }], responses: { "201" => { description: "成功" } } }
      },
      "/api/v1/groups/{ref_key}" => {
        get: { summary: "分组详情", tags: ["Groups"], security: [{ BearerAuth: [] }], parameters: [ { name: "ref_key", in: "path", required: true, schema: { type: "string" } } ], responses: { "200" => { description: "成功" } } },
        patch: { summary: "更新分组", tags: ["Groups"], security: [{ BearerAuth: [] }], parameters: [ { name: "ref_key", in: "path", required: true, schema: { type: "string" } } ], responses: { "200" => { description: "成功" } } },
        delete: { summary: "删除分组", tags: ["Groups"], security: [{ BearerAuth: [] }], parameters: [ { name: "ref_key", in: "path", required: true, schema: { type: "string" } } ], responses: { "204" => { description: "成功" } } }
      }
    }
  end

  def event_research_run_paths
    {
      "/api/v1/event_research_runs" => {
        get: {
          summary: "查询活动调研运行记录",
          description: "活动调研（Event Research）的运行记录列表。latest=true 时只返回每个账号最近一次成功调研。",
          tags: ["EventResearch"],
          security: [{ BearerAuth: [] }],
          parameters: [
            { name: "account_id", in: "query", schema: { type: "integer" }, description: "按活动账号过滤" },
            { name: "status", in: "query", schema: { type: "string", enum: %w[pending running completed failed] }, description: "按状态过滤" },
            { name: "latest", in: "query", schema: { type: "string", enum: %w[true false] }, description: "只看每个账号最近一次成功调研" },
            { name: "page", in: "query", schema: { type: "integer", default: 1, minimum: 1 }, description: "可选：页码，默认 1" },
            { name: "per_page", in: "query", schema: { type: "integer", default: 25, minimum: 1, maximum: 100 }, description: "可选：每页数量，默认 25，最大 100" }
          ],
          responses: {
            "200" => {
              description: "成功",
              content: { "application/json" => { schema: {
                type: "object",
                properties: {
                  event_research_runs: { type: "array", items: { "$ref" => "#/components/schemas/EventResearchRun" } },
                  pagination: { "$ref" => "#/components/schemas/Pagination" }
                }
              }}}
            }
          }
        }
      },
      "/api/v1/event_research_runs/{id}" => {
        get: {
          summary: "获取调研运行详情（含完整结果 JSON）",
          tags: ["EventResearch"],
          security: [{ BearerAuth: [] }],
          parameters: [ { name: "id", in: "path", required: true, schema: { type: "integer" } } ],
          responses: { "200" => { description: "成功" } }
        }
      }
    }
  end

  def account_schema
    {
      "Account" => {
        type: "object",
        properties: {
          id: { type: "integer" }, fakeid: { type: "string" }, nickname: { type: "string" },
          platform: { type: "string" }, status: { type: "string" }, activity_level: { type: "string" },
          activity_score: { type: "integer" }, total_articles: { type: "integer" },
          articles_last_7_days: { type: "integer" }, articles_last_30_days: { type: "integer" },
          last_published_at: { type: "string", format: "date-time", nullable: true },
          tags: { type: "array", items: { "$ref" => "#/components/schemas/TagRef" } },
        }
      }
    }
  end

  def article_schema
    { "Article" => { type: "object", properties: { id: { type: "integer" }, title: { type: "string" }, url: { type: "string" }, digest: { type: "string", nullable: true }, published_at: { type: "string", format: "date-time", nullable: true } } } }
  end

  def tag_schema
    {
      "Tag" => { type: "object", properties: { id: { type: "integer" }, name: { type: "string" }, color: { type: "string" }, accounts_count: { type: "integer" } } },
      "TagRef" => { type: "object", properties: { id: { type: "integer" }, name: { type: "string" }, color: { type: "string" } } }
    }
  end

  def group_schema
    { "Group" => { type: "object", properties: { ref_key: { type: "string" }, accounts: { type: "array", items: { type: "object" } } } } }
  end

  def event_research_run_schema
    {
      "EventResearchRun" => {
        type: "object",
        properties: {
          id: { type: "integer" },
          account: { type: "object", properties: { id: { type: "integer" }, nickname: { type: "string" }, type: { type: "string" } } },
          status: { type: "string", enum: %w[pending running completed failed] },
          refresh_cache: { type: "boolean" },
          people_count: { type: "integer", nullable: true },
          award_count: { type: "integer", nullable: true },
          company_count: { type: "integer", nullable: true },
          error_message: { type: "string", nullable: true },
          started_at: { type: "string", format: "date-time", nullable: true },
          completed_at: { type: "string", format: "date-time", nullable: true },
          created_at: { type: "string", format: "date-time" },
          result: { type: "object", description: "完整调研结果 JSON（仅 show 接口返回）：event / awards / companies / metadata", nullable: true }
        }
      }
    }
  end

  def pagination_schema
    { "Pagination" => { type: "object", properties: { page: { type: "integer" }, per_page: { type: "integer" }, total_count: { type: "integer" }, total_pages: { type: "integer" } } } }
  end
end
