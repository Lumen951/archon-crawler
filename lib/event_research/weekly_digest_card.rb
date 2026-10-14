class EventResearch::WeeklyDigestCard
  MAX_REQUEST_BYTES = 20_000
  MAX_FIELD_CHARS = 500
  MAX_ITEMS = 10

  def self.call(digest, receive_id: "")
    new(digest, receive_id: receive_id).call
  end

  def initialize(digest, receive_id:)
    @digest = digest
    @receive_id = receive_id
    @sections = digest.sections.is_a?(Hash) ? digest.sections : {}
  end

  def call
    blocks = content_blocks
    omitted = false
    loop do
      card = build_card(blocks, omitted)
      return card if request_bytes(card) <= MAX_REQUEST_BYTES

      raise ArgumentError, "报告卡片固定内容超过大小预算" if blocks.empty?

      blocks.pop
      omitted = true
    end
  end

  private

  def content_blocks
    if @sections.empty? && @digest.payload_text.present?
      return @digest.payload_text.lines.first(MAX_ITEMS).map { |line| clean(line) }
    end

    highlights = @sections["highlights"].is_a?(Hash) ? @sections["highlights"] : {}
    blocks = []
    { "people" => "重点人脉", "projects" => "新增项目", "companies" => "新增公司/机构",
      "awards" => "奖项/入选/路演", "contacts" => "可跟进联系方式" }.each do |key, heading|
      items = Array(highlights[key]).select { |item| item.is_a?(Hash) }
      items.first(MAX_ITEMS).each_with_index do |item, index|
        title = key == "contacts" ? EventResearch::Intelligence.contact_label(item) :
          [ item["name"], item["role_or_title"], item["company"] ].filter_map(&:presence).join("｜")
        details = [ item["project"], item["stage_or_context"], item["description"],
          item["recipient_person"], item["recipient_company_or_project"], item["belongs_to"], item["context"] ].filter_map(&:presence)
        details << Array(item["awards"]).first(MAX_ITEMS).join("、") if Array(item["awards"]).any?
        details.concat(Array(item["contact_methods"]).first(MAX_ITEMS).filter_map { |contact| EventResearch::Intelligence.contact_label(contact) })
        evidence = EventResearch::Intelligence.evidence_label(item)
        details << "证据：#{evidence}" if evidence.present?
        prefix = index.zero? ? "**#{heading}**\n" : ""
        blocks << "#{prefix}#{index + 1}. #{clean(title)}\n#{details.map { |detail| clean(detail) }.join("\n")}"
      end
      blocks << "另有 **#{items.length - MAX_ITEMS}** 条#{heading}，请查看详情。" if items.length > MAX_ITEMS
    end
    blocks << "本次暂未提取到新的创业人脉情报。" if blocks.empty?
    events = Array(@sections["events"]).select { |event| event.is_a?(Hash) }
    events.first(MAX_ITEMS).each_with_index do |event, index|
      text = event["note"].present? ? clean(event["note"]) :
        "新增人脉 **#{event['new_people_total'].to_i}**，项目 **#{event['projects_total'].to_i}**，联系方式 **#{event['contacts_total'].to_i}**"
      blocks << "#{index.zero? ? "**按活动查看**\n" : ""}#{clean(event['nickname'])}：#{text}"
    end
    blocks << "另有 **#{events.length - MAX_ITEMS}** 个活动，请查看详情。" if events.length > MAX_ITEMS
    blocks
  end

  def build_card(blocks, omitted)
    elements = [ markdown(summary_text) ]
    elements.concat(blocks.map { |block| markdown(block) })
    elements << markdown("报告较长，部分内容未展示，请查看完整报告。") if omitted
    elements << { tag: "action", actions: [ { tag: "button", type: "primary",
      text: { tag: "plain_text", content: "查看研究报告详情" }, url: digest_url } ] }
    { config: { wide_screen_mode: true },
      header: { template: "blue", title: { tag: "plain_text", content: "#{@digest.title}（#{@digest.period_label}）" } },
      elements: elements }
  end

  def summary_text
    summary = @sections["summary"].is_a?(Hash) ? @sections["summary"] : {}
    usage = @sections["api_usage"].is_a?(Hash) ? @sections["api_usage"] : {}
    text = "覆盖 **#{summary['events'].to_i}** 个活动 · 重点人脉 **#{summary['people'].to_i}** 位 · 项目 **#{summary['projects'].to_i}** 个 · 奖项/入选 **#{summary['awards'].to_i}** 条 · 联系方式 **#{summary['contacts'].to_i}** 条\n\n**调用与缓存统计**"
    { "search" => "搜索", "tianyancha" => "天眼查" }.each do |key, label|
      counts = usage[key].is_a?(Hash) ? usage[key] : {}
      text << "\n#{label} API **#{counts['api_calls'].to_i}** / 缓存命中 **#{counts['cache_hits'].to_i}**"
    end
    text
  end

  def clean(value)
    value.to_s.gsub(/[\x00-\x1f\x7f]/, " ").tr('*`[]<>_\\', '＊｀［］＜＞＿＼').truncate(MAX_FIELD_CHARS)
  end

  def markdown(content)
    { tag: "div", text: { tag: "lark_md", content: content } }
  end

  def request_bytes(card)
    { receive_id: @receive_id, msg_type: "interactive", content: card.to_json }.to_json.bytesize
  end

  def digest_url
    options = { host: ENV["APP_HOST"].presence || "localhost" }
    options.merge!(Rails.env.production? ? { protocol: "https" } : { protocol: "http", port: 3000 })
    Rails.application.routes.url_helpers.event_weekly_digest_url(@digest, **options)
  end
end
