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
      paths: account_paths.merge(article_paths).merge(tag_paths).merge(group_paths),
      components: {
        securitySchemes: {
          BearerAuth: {
            type: "http",
            scheme: "bearer",
            description: "在 /profile 页面创建 API Key"
          }
        },
        schemas: account_schema.merge(article_schema).merge(tag_schema).merge(group_schema).merge(pagination_schema)
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
            { name: "platform", in: "query", schema: { type: "string", enum: %w[wechat rednote twitter] }, description: "按平台过滤" },
            { name: "status", in: "query", schema: { type: "string", enum: %w[active inactive] }, description: "按状态过滤" },
            { name: "activity_level", in: "query", schema: { type: "string", enum: %w[active slow dormant dead never uncrawled] }, description: "按活跃度过滤" },
            { name: "tag_id", in: "query", schema: { type: "integer" }, description: "按标签 ID 过滤" },
            { name: "keyword", in: "query", schema: { type: "string" }, description: "按账号名称搜索" },
            { name: "page", in: "query", schema: { type: "integer", default: 1 } },
            { name: "per_page", in: "query", schema: { type: "integer", default: 25, maximum: 100 } },
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
            { name: "id", in: "query", schema: { type: "string" } },
            { name: "name", in: "query", schema: { type: "string" } },
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
            { name: "account_id", in: "query", schema: { type: "integer" }, description: "按账号查询" },
            { name: "start_date", in: "query", schema: { type: "string", format: "date" } },
            { name: "end_date", in: "query", schema: { type: "string", format: "date" } },
            { name: "group_ref_keys[]", in: "query", schema: { type: "array", items: { type: "string" } } },
            { name: "range[]", in: "query", schema: { type: "array", items: { type: "string", format: "date" } } },
            { name: "page", in: "query", schema: { type: "integer", default: 1 } },
            { name: "per_page", in: "query", schema: { type: "integer", default: 25 } },
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

  def pagination_schema
    { "Pagination" => { type: "object", properties: { page: { type: "integer" }, per_page: { type: "integer" }, total_count: { type: "integer" }, total_pages: { type: "integer" } } } }
  end
end
