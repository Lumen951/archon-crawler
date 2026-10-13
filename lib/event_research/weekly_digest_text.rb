# 将一个研究任务的结构化 sections（EventResearch::WeeklyDigestBuilder 产物）渲染成
# 飞书纯文本。正文以「创业人脉情报」为中心：先给全局重点人脉、项目、
# 奖项和可跟进联系方式，再补充按活动查看的简要概况。
class EventResearch::WeeklyDigestText
  MAX_CHARS = 12_000
  MAX_EVENTS = 10

  def self.call(digest)
    new(digest).call
  end

  def initialize(digest)
    @digest = digest
    @sections = digest.sections.is_a?(Hash) ? digest.sections : {}
    @highlights = @sections["highlights"].is_a?(Hash) ? @sections["highlights"] : {}
  end

  def call
    finalize(header + highlights_text + events_text)
  end

  private

  def header
    summary = @sections["summary"].is_a?(Hash) ? @sections["summary"] : {}
    "📋 活动研究报告（#{@digest.period_label}）\n" \
      "覆盖 #{summary['events'].to_i} 个活动 · 重点人脉 #{summary['people'].to_i} 位 · " \
      "项目 #{summary['projects'].to_i} 个 · 奖项/入选 #{summary['awards'].to_i} 条 · " \
      "联系方式 #{summary['contacts'].to_i} 条\n\n"
  end

  def highlights_text
    text = +""
    text << people_text(Array(@highlights["people"]))
    text << projects_text(Array(@highlights["projects"]))
    text << companies_text(Array(@highlights["companies"]))
    text << awards_text(Array(@highlights["awards"]))
    text << contacts_text(Array(@highlights["contacts"]))
    text.presence || "本次暂未提取到新的创业人脉情报。\n\n"
  end

  def people_text(people)
    return "" if people.empty?

    text = "重点人脉\n"
    people.each_with_index do |person, index|
      text << "#{index + 1}. #{person_line(person)}\n"
      details = []
      details << "项目：#{person['project']}" if person["project"].present?
      details << "奖项/事件：#{Array(person['awards']).join('、')}" if Array(person["awards"]).any?
      details << "描述：#{person['description']}" if person["description"].present?
      contacts = Array(person["contact_methods"]).filter_map { |contact| EventResearch::Intelligence.contact_label(contact) }
      details << "联系方式：#{contacts.join(' ｜ ')}" if contacts.any?
      details << evidence_line(person)
      text << details.compact.map { |line| "   #{line}" }.join("\n") << "\n"
    end
    text << "\n"
  end

  def projects_text(projects)
    return "" if projects.empty?

    text = "新增项目\n"
    projects.each do |project|
      title = [ project["name"], project["company"] ].filter_map(&:presence).join("｜")
      details = [ project["stage_or_context"], project["description"], evidence_line(project) ].filter_map(&:presence)
      text << "- #{title}#{details.any? ? "：#{details.join('；')}" : ""}\n"
    end
    text << "\n"
  end

  def companies_text(companies)
    return "" if companies.empty?

    text = "新增公司/机构\n"
    companies.each do |company|
      title = [ company["name"], company["industry"] ].filter_map(&:presence).join("｜")
      details = [ company["project"], company["description"], evidence_line(company) ].filter_map(&:presence)
      text << "- #{title}#{details.any? ? "：#{details.join('；')}" : ""}\n"
    end
    text << "\n"
  end

  def awards_text(awards)
    return "" if awards.empty?

    text = "奖项/入选/路演\n"
    awards.each do |award|
      recipient = award["recipient_person"].presence || award["recipient_company_or_project"]
      details = [ recipient, award["event_name"], award["date"], evidence_line(award) ].filter_map(&:presence)
      text << "- #{award['name']}#{details.any? ? "：#{details.join('；')}" : ""}\n"
    end
    text << "\n"
  end

  def contacts_text(contacts)
    return "" if contacts.empty?

    text = "可跟进联系方式\n"
    contacts.each do |contact|
      label = EventResearch::Intelligence.contact_label(contact)
      details = [ contact["belongs_to"], contact["context"], evidence_line(contact) ].filter_map(&:presence)
      text << "- #{label}#{details.any? ? "：#{details.join('；')}" : ""}\n"
    end
    text << "\n"
  end

  def events_text
    events = Array(@sections["events"])
    return "" if events.empty?

    text = "按活动查看\n"
    events.first(MAX_EVENTS).each do |event|
      if event["note"].present?
        text << "▍#{event['nickname']}：#{event['note']}\n"
      else
        totals = event["totals"].is_a?(Hash) ? event["totals"] : {}
        text << "▍#{event['nickname']}：新增人脉 #{event['new_people_total'].to_i}，项目 #{event['projects_total'].to_i}，联系方式 #{event['contacts_total'].to_i}"
        text << "（run##{event['run_id']}）" if event["run_id"].present?
        text << "\n"
        text << "   概况：获奖 #{totals['awards'].to_i} · 人物 #{totals['people'].to_i} · 公司 #{totals['companies'].to_i} · 项目 #{totals['projects'].to_i}\n"
      end
    end
    text << "- 另有 #{events.length - MAX_EVENTS} 个活动未展示\n" if events.length > MAX_EVENTS
    text << "\n"
  end

  def person_line(person)
    [ person["name"], person["role_or_title"], person["company"] ].filter_map(&:presence).join("｜")
  end

  def evidence_line(item)
    label = EventResearch::Intelligence.evidence_label(item)
    "证据：#{label}" if label.present?
  end

  def finalize(text)
    link = "查看研究报告详情：#{digest_url}"
    prefix = text.to_s.truncate(MAX_CHARS - link.length - 2, omission: "…")
    "#{prefix.rstrip}\n\n#{link}"
  end

  def digest_url
    options = { host: ENV["APP_HOST"].presence || "localhost" }
    options.merge!(Rails.env.production? ? { protocol: "https" } : { protocol: "http", port: 3000 })
    Rails.application.routes.url_helpers.event_weekly_digest_url(@digest, **options)
  end
end
