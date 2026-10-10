class EventResearch::NotificationSummary
  MAX_CHARS = 12_000

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
    header("完整研究结果") + render_result(@result)
  end

  def weekly(diff)
    return if diff.blank? || diff["empty"]

    text = header("本周新增与补充")
    text << section("新增奖项/项目", diff["awards"])
    text << section("新增公司", diff["companies"])
    text << section("新增人物", diff["people"])
    text << section("已有信息补充", diff["updates"])
    text.truncate(MAX_CHARS)
  end

  private

  def header(title)
    "#{title}：#{@account.nickname}\n研究运行 ##{@run.id}（#{@run.completed_at&.strftime('%Y-%m-%d %H:%M')}）\n\n"
  end

  def render_result(result)
    text = section("奖项/项目", result["awards"])
    text << section("公司", result["companies"])
    text.truncate(MAX_CHARS)
  end

  def section(title, items)
    values = Array(items)
    return "" if values.empty?

    "#{title}（#{values.length}）\n" + values.map { |item| "- #{format_item(item)}" }.join("\n") + "\n\n"
  end

  def format_item(item)
    return item.to_s unless item.is_a?(Hash)

    label = item["name"].presence || item["award"].presence || item["rank"].presence || "条目"
    details = item.except("people", "_award").filter_map { |key, value| "#{key}: #{value}" unless value.blank? || value.is_a?(Hash) || value.is_a?(Array) }
    ([ label ] + details).join("；")
  end
end
