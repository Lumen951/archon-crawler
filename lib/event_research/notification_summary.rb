class EventResearch::NotificationSummary
  MAX_CHARS = 12_000
  MAX_AWARDS = 12
  MAX_COMPANIES = 10
  MAX_PEOPLE = 10
  MAX_UPDATES = 10
  MAX_VALUE_LENGTH = 120

  def self.initial(account, run)
    new(account, run).initial
  end

  def self.weekly(account, run, diff)
    new(account, run).weekly(diff)
  end

  def initialize(account, run)
    @account = account
    @run = run
    @result = run.result.is_a?(Hash) ? run.result : {}
  end

  def initial
    finalize(header("完整研究结果") + render_result(@result))
  end

  def weekly(diff)
    return if diff.blank? || diff["empty"]

    text = header("本周新增与补充")
    text << section("新增奖项/项目", award_entries(diff["awards"]), source_count: Array(diff["awards"]).length, limit: MAX_AWARDS)
    text << section("新增公司", company_entries(diff["companies"]), source_count: Array(diff["companies"]).length, limit: MAX_COMPANIES)
    text << section("新增人物", people_entries(diff["people"]), source_count: Array(diff["people"]).length, limit: MAX_PEOPLE)
    text << section("已有信息补充", update_entries(diff["updates"]), source_count: Array(diff["updates"]).length, limit: MAX_UPDATES)
    finalize(text)
  end

  private

  def header(title)
    "#{title}：#{@account.nickname}\n研究运行 ##{@run.id}（#{@run.completed_at&.strftime('%Y-%m-%d %H:%M')}）\n\n"
  end

  def finalize(text)
    link = "查看完整研究结果：#{research_url}"
    prefix = text.to_s.truncate(MAX_CHARS - link.length - 2, omission: "…")
    "#{prefix.rstrip}\n\n#{link}"
  end

  def research_url
    options = { host: ENV["APP_HOST"].presence || "localhost", run_id: @run.id }
    options.merge!(Rails.env.production? ? { protocol: "https" } : { protocol: "http", port: 3000 })
    Rails.application.routes.url_helpers.event_account_url(@account, **options)
  end

  def render_result(result)
    awards = Array(result["awards"])
    companies = Array(result["companies"])
    text = section("奖项/项目", award_entries(awards), source_count: awards.length, limit: MAX_AWARDS)
    text << section("公司", company_entries(companies), source_count: companies.length, limit: MAX_COMPANIES)
    text
  end

  def section(title, entries, source_count:, limit:)
    return "" if entries.empty?

    count = source_count == entries.length ? source_count.to_s : "#{source_count} 条，去重后 #{entries.length} 条"
    shown = entries.first(limit)
    lines = shown.map { |entry| "- #{entry}" }
    lines << "- 另有 #{entries.length - shown.length} 条未展示" if entries.length > shown.length
    "#{title}（#{count}）\n#{lines.join("\n")}\n\n"
  end

  def award_entries(items)
    Array(items).filter_map { |item| format_award(item) }.uniq
  end

  def format_award(item)
    return fallback_item(item) unless item.is_a?(Hash)

    rank = compact_value(item["rank"].presence || item["award"])
    category = compact_value(item["category"])
    rank_without_category = category.present? ? rank.delete_prefix(category).strip : rank
    label = join_values(category, rank_without_category.presence || rank)
    project = item["project"].is_a?(Hash) ? item["project"] : {}
    context = join_values(project["name"], project["organization"], project["industry"])
    join_values(label.presence || "奖项/项目", context, separator: "｜")
  end

  def company_entries(items)
    unique_by(Array(items)) do |item|
      item.is_a?(Hash) && item["name"].present? ? normalize(item["name"]) : fallback_item(item)
    end.filter_map { |item| format_company(item) }
  end

  def format_company(item)
    return fallback_item(item) unless item.is_a?(Hash)

    name = compact_value(item["name"]).presence || "公司"
    details = []
    details << compact_value(item["industry"]) if item["industry"].present?
    details << compact_value(item["status"]) if item["status"].present?
    details << "成立 #{compact_value(item['established_at'])}" if item["established_at"].present?
    details << "官网 #{compact_value(item['website'])}" if item["website"].present?
    tags = format_tags(item["tags"])
    details << "标签 #{tags}" if tags.present?
    join_values(name, details.join("；"), separator: "｜")
  end

  def people_entries(items)
    unique_by(Array(items)) do |item|
      if item.is_a?(Hash)
        [ normalize(item["name"]), normalize(item["_award"]) ].join("|")
      else
        fallback_item(item)
      end
    end.filter_map { |item| format_person(item) }
  end

  def format_person(item)
    return fallback_item(item) unless item.is_a?(Hash)

    name = compact_value(item["name"]).presence || "人物"
    details = []
    details << compact_value(item["role"]) if item["role"].present?
    details << "关联 #{compact_value(item['_award'])}" if item["_award"].present?
    join_values(name, details.join("；"), separator: "｜")
  end

  def update_entries(items)
    Array(items).filter_map { |item| format_update(item) }.uniq
  end

  def format_update(item)
    return fallback_item(item) unless item.is_a?(Hash)

    before = item["before"].is_a?(Hash) ? item["before"] : {}
    after = item["after"].is_a?(Hash) ? item["after"] : {}
    kind = item["key"].to_s.split("|", 2).first
    label, fields = case kind
    when "company"
      [ compact_value(after["name"]).presence || "公司", newly_populated_fields(before, after, company_update_fields) ]
    when "person"
      [ compact_value(after["name"]).presence || "人物", newly_populated_fields(before, after, person_update_fields) ]
    else
      [ award_label(after), newly_populated_fields(before, after, award_update_fields) ]
    end

    return if fields.empty?

    "#{label}｜新增 #{fields.join('、')}"
  end

  def company_update_fields
    {
      "industry" => "行业",
      "status" => "经营状态",
      "established_at" => "成立日期",
      "website" => "官网",
      "tags" => "标签"
    }
  end

  def person_update_fields
    {
      "role" => "角色",
      "_award" => "关联奖项"
    }
  end

  def award_update_fields
    {
      "category" => "组别",
      "rank" => "奖项等级",
      "award" => "奖项",
      "project.name" => "项目名称",
      "project.organization" => "项目单位",
      "project.industry" => "项目行业"
    }
  end

  def newly_populated_fields(before, after, fields)
    fields.filter_map do |path, label|
      old_value = value_at(before, path)
      new_value = value_at(after, path)
      label if blank?(old_value) && !blank?(new_value)
    end
  end

  def award_label(item)
    format_award(item).to_s.split("｜", 2).first.presence || "奖项/项目"
  end

  def value_at(item, path)
    path.split(".").reduce(item) { |value, key| value.is_a?(Hash) ? value[key] : nil }
  end

  def format_tags(value)
    values = value.is_a?(Array) ? value : value.to_s.split(/[；;,]/)
    values.filter_map { |tag| compact_value(tag).presence }.first(3).join("、")
  end

  def unique_by(items)
    seen = {}
    items.each_with_object([]) do |item, result|
      key = yield(item)
      next if seen[key]

      seen[key] = true
      result << item
    end
  end

  def join_values(*values, separator: " · ")
    values.filter_map { |value| compact_value(value).presence }.join(separator)
  end

  def compact_value(value)
    value.to_s.squish.truncate(MAX_VALUE_LENGTH)
  end

  def fallback_item(item)
    compact_value(item).presence
  end

  def normalize(value)
    value.to_s.downcase.gsub(/\s+/, "").strip
  end

  def blank?(value)
    value.blank? || (value.is_a?(Array) && value.empty?)
  end
end
