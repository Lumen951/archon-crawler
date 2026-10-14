# 将一个活动研究任务的成员运行记录聚合为结构化报告。
class EventResearch::WeeklyDigestBuilder
  MAX_HIGHLIGHT_PEOPLE = 12
  MAX_HIGHLIGHT_ITEMS = 10
  MAX_ITEMS_PER_EVENT = 8

  def self.call(task)
    new(task).call
  end

  def initialize(task)
    @task = task
    @items = task.event_research_task_accounts.includes(:account, :event_research_run).order(:id)
  end

  def call
    events = @items.filter_map { |item| event_section(item) }
    highlights = build_highlights(events)

    {
      "task_id" => @task.id,
      "source" => @task.source,
      "created_at" => @task.created_at.iso8601,
      "summary" => summary(events),
      "api_usage" => @task.api_usage(@items),
      "highlights" => highlights,
      "events" => events
    }
  end

  private

  def event_section(item)
    account = item.account
    run = item.event_research_run
    return task_status_section(item) unless item.completed? && run&.completed?

    baseline_run = account.event_research_runs.completed.where("completed_at < ?", run.completed_at).order(completed_at: :desc).first

    current = annotate_intelligence(EventResearch::Intelligence.normalize(run.result), account, run)
    baseline = EventResearch::Intelligence.normalize(baseline_run&.result)

    people = new_items("people", current, baseline).then { |items| rank_people(items) }
    projects = new_items("projects", current, baseline).then { |items| rank_items(items) }
    companies = new_items("companies", current, baseline).then { |items| rank_items(items) }
    awards = new_items("awards", current, baseline).then { |items| rank_items(items) }
    contacts = new_items("contacts", current, baseline).then { |items| rank_contacts(items) }

    section = {
      "account_id" => account.id,
      "nickname" => account.nickname,
      "run_id" => run.id,
      "completed_at" => run.completed_at&.iso8601,
      "baseline_run_id" => baseline_run&.id,
      "totals" => run_totals(run, current),
      "new_people" => people.first(MAX_ITEMS_PER_EVENT),
      "new_people_total" => people.length,
      "projects" => projects.first(MAX_ITEMS_PER_EVENT),
      "projects_total" => projects.length,
      "companies" => companies.first(MAX_ITEMS_PER_EVENT),
      "companies_total" => companies.length,
      "awards" => awards.first(MAX_ITEMS_PER_EVENT),
      "awards_total" => awards.length,
      "contacts" => contacts.first(MAX_ITEMS_PER_EVENT),
      "contacts_total" => contacts.length,
      "updates" => person_updates(baseline, current)
    }

    hidden = people.length - MAX_ITEMS_PER_EVENT
    section["note"] = "另有 #{hidden} 位新增人物未展示" if hidden.positive?
    section
  end

  def task_status_section(item)
    note = case item.status
    when "skipped" then "本次任务已跳过（#{item.error_message.presence || "已有进行中的调研"}）"
    when "failed" then "本次调研失败（#{item.error_message.presence || "未知原因"}）"
    else "本次调研未完成"
    end

    { "account_id" => item.account_id, "nickname" => item.account.nickname, "run_id" => item.event_research_run_id, "note" => note }
  end

  def annotate_intelligence(intelligence, account, run)
    EventResearch::Intelligence::CATEGORIES.index_with do |category|
      Array(intelligence[category]).each_with_index.map do |item, index|
        item.merge(
          "account_id" => account.id,
          "event_nickname" => account.nickname,
          "run_id" => run.id,
          "completed_at" => run.completed_at&.iso8601,
          "_order" => index
        )
      end
    end
  end

  def new_items(category, current, baseline)
    baseline_keys = Array(baseline[category]).to_h { |item| [ item_key(category, item), true ] }
    Array(current[category]).reject { |item| baseline_keys[item_key(category, item)] }
  end

  def build_highlights(events)
    completed_events = events.reject { |event| event["note"].present? }
    {
      "people" => rank_people(completed_events.flat_map { |event| Array(event["new_people"]) }).first(MAX_HIGHLIGHT_PEOPLE),
      "projects" => rank_items(completed_events.flat_map { |event| Array(event["projects"]) }).first(MAX_HIGHLIGHT_ITEMS),
      "companies" => rank_items(completed_events.flat_map { |event| Array(event["companies"]) }).first(MAX_HIGHLIGHT_ITEMS),
      "awards" => rank_items(completed_events.flat_map { |event| Array(event["awards"]) }).first(MAX_HIGHLIGHT_ITEMS),
      "contacts" => rank_contacts(completed_events.flat_map { |event| Array(event["contacts"]) }).first(MAX_HIGHLIGHT_ITEMS)
    }
  end

  def summary(events)
    completed_events = events.reject { |event| event["note"].present? }
    {
      "events" => events.length,
      "people" => completed_events.sum { |event| event["new_people_total"].to_i },
      "companies" => completed_events.sum { |event| event["companies_total"].to_i },
      "projects" => completed_events.sum { |event| event["projects_total"].to_i },
      "awards" => completed_events.sum { |event| event["awards_total"].to_i },
      "contacts" => completed_events.sum { |event| event["contacts_total"].to_i }
    }
  end

  def rank_people(items)
    items.each_with_index.sort_by do |item, index|
      [
        contacts_for_person(item).any? ? 0 : 1,
        important_context?(item) ? 0 : 1,
        confidence_rank(item),
        -evidence_count(item),
        item["_order"].to_i,
        index
      ]
    end.map { |item, _index| item.except("_order") }
  end

  def rank_contacts(items)
    items.each_with_index.sort_by do |item, index|
      [ confidence_rank(item), -evidence_count(item), item["_order"].to_i, index ]
    end.map { |item, _index| item.except("_order") }
  end

  def rank_items(items)
    items.each_with_index.sort_by do |item, index|
      [
        item_contacts(item).any? ? 0 : 1,
        important_context?(item) ? 0 : 1,
        confidence_rank(item),
        -evidence_count(item),
        item["_order"].to_i,
        index
      ]
    end.map { |item, _index| item.except("_order") }
  end

  def person_updates(baseline, current)
    baseline_people = Array(baseline["people"]).to_h { |person| [ item_key("people", person), person ] }
    Array(current["people"]).filter_map do |person|
      old = baseline_people[item_key("people", person)]
      next unless old

      fields = []
      fields << "角色" if old["role_or_title"].blank? && person["role_or_title"].present?
      fields << "公司" if old["company"].blank? && person["company"].present?
      fields << "项目" if old["project"].blank? && person["project"].present?
      fields << "联系方式" if contacts_for_person(old).empty? && contacts_for_person(person).any?
      "#{person['name']}｜新增 #{fields.join('、')}" if fields.any?
    end
  end

  def run_totals(run, intelligence)
    {
      "awards" => Array(intelligence["awards"]).length.presence || Array(run.result.is_a?(Hash) ? run.result["awards"] : []).length,
      "people" => Array(intelligence["people"]).length.presence || run.people_count.to_i,
      "companies" => Array(intelligence["companies"]).length,
      "projects" => Array(intelligence["projects"]).length,
      "contacts" => Array(intelligence["contacts"]).length
    }
  end

  def item_key(category, item)
    case category
    when "people"
      [ item["name"], item["company"], item["project"] ].map { |value| normalize(value) }.join("|")
    when "projects"
      [ item["name"], item["company"] ].map { |value| normalize(value) }.join("|")
    when "companies"
      normalize(item["name"])
    when "contacts"
      [ item["type"], item["value"], item["belongs_to"] ].map { |value| normalize(value) }.join("|")
    when "awards"
      [ item["name"], item["recipient_person"], item["recipient_company_or_project"] ].map { |value| normalize(value) }.join("|")
    end
  end

  def contacts_for_person(person)
    Array(person["contact_methods"]) + Array(person["contacts"])
  end

  def item_contacts(item)
    Array(item["contacts"]) + Array(item["contact_methods"])
  end

  def important_context?(item)
    text = [ item["description"], item["stage_or_context"], item["awards"], item["name"], item["context"] ].flatten.compact.join(" ")
    text.match?(/奖|获|入选|融资|路演|创业|孵化|加速|冠军|优胜|demo|pitch/i)
  end

  def confidence_rank(item)
    { "high" => 0, "medium" => 1, "low" => 2 }.fetch(item["confidence"].to_s, 1)
  end

  def evidence_count(item)
    Array(item["evidence"]).length
  end

  def normalize(value)
    EventResearch::Intelligence.normalize_key(value)
  end
end
