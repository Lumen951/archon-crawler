# 活动调研的搜索组合构建器：固定模板与账号配置的追加关键词共用这一份定义，
# 以保证界面展示与实际发送给搜索服务的查询一致。
class EventResearch::QueryBuilder
  FIXED_QUERY_TEMPLATES = [
    '"%<event>s" 获奖名单',
    '"%<event>s" 获奖项目',
    '"%<event>s" 获奖人',
    '"%<event>s" 决赛 获奖',
    '"%<event>s" 总决赛',
    '"%<event>s" 一等奖 二等奖 三等奖',
    '"%<event>s" TOP50',
    '"%<event>s" TOP100',
    '"%<event>s" 排名',
    '"%<event>s" 项目名单',
    '"%<event>s" 参赛项目',
    '"%<event>s" 创始人',
    '"%<event>s" CEO'
  ].freeze

  def initialize(event:, keywords: [])
    @event = event.to_s.strip
    @keywords = Array(keywords).map { |keyword| keyword.to_s.scrub.strip }.reject(&:empty?)
  end

  def fixed_queries
    FIXED_QUERY_TEMPLATES.map { |template| format(template, event: @event) }
  end

  def appended_queries
    @keywords.map { |keyword| "#{@event} #{keyword}" }
  end

  def queries
    fixed_queries + appended_queries
  end
end
