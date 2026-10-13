# JSON-first helpers for event research networking intelligence.
#
# The normalized shape is deliberately stored inside EventResearchRun.result rather
# than split into relational lead tables for now. This keeps the extraction schema
# cheap to iterate while giving weekly digests a stable reader API.
module EventResearch::Intelligence
  CATEGORIES = %w[people companies projects awards contacts].freeze
  CONTACT_TYPES = %w[email phone website url form wechat other].freeze

  module_function

  def normalize(result)
    result = result.is_a?(Hash) ? result.deep_stringify_keys : {}
    explicit = result["intelligence"].is_a?(Hash) ? result["intelligence"].deep_stringify_keys : nil
    source = explicit.present? ? explicit : legacy_intelligence(result)

    CATEGORIES.index_with do |category|
      Array(source[category]).filter_map { |item| normalize_item(category, item) }
    end
  end

  def normalize_result(result)
    data = result.is_a?(Hash) ? result.deep_stringify_keys : {}
    data["intelligence"] = normalize(data)
    data
  end

  def people(result)
    normalize(result)["people"]
  end

  def companies(result)
    normalize(result)["companies"]
  end

  def projects(result)
    normalize(result)["projects"]
  end

  def awards(result)
    normalize(result)["awards"]
  end

  def contacts(result)
    normalize(result)["contacts"]
  end

  def primary_evidence(item)
    Array(item.is_a?(Hash) ? item["evidence"] : []).find { |evidence| evidence.is_a?(Hash) && evidence.values.any?(&:present?) } || {}
  end

  def evidence_label(item)
    evidence = primary_evidence(item)
    [ evidence["quote"], evidence["source_url"] ].filter_map { |value| compact(value).presence }.join(" ｜ ")
  end

  def contact_label(contact)
    return nil unless contact.is_a?(Hash)

    type = compact(contact["type"]).presence || "contact"
    value = compact(contact["value"]).presence
    return nil unless value

    type_label = case type
    when "email" then "邮箱"
    when "phone" then "电话"
    when "website", "url" then "链接"
    when "wechat" then "微信"
    when "form" then "表单"
    else "联系方式"
    end
    "#{type_label} #{value}"
  end

  def normalize_key(value)
    value.to_s.downcase.gsub(/[\s　]+/, "").strip
  end

  def compact(value, length: 160)
    value.to_s.squish.truncate(length)
  end

  def presence_array(value)
    Array(value).filter_map { |item| compact(item).presence }.uniq
  end

  def normalize_item(category, item)
    return nil unless item.is_a?(Hash)

    item = item.deep_stringify_keys
    case category
    when "people" then normalize_person(item)
    when "companies" then normalize_company(item)
    when "projects" then normalize_project(item)
    when "awards" then normalize_award(item)
    when "contacts" then normalize_contact(item)
    end
  end

  def normalize_person(item)
    name = compact(item["name"]).presence
    return nil unless name

    {
      "name" => name,
      "role_or_title" => compact(item["role_or_title"].presence || item["role"]).presence,
      "company" => compact(item["company"].presence || item["organization"]).presence,
      "project" => compact(item["project"]).presence,
      "description" => compact(item["description"], length: 280).presence,
      "awards" => presence_array(item["awards"]),
      "contact_methods" => normalize_contacts(item["contact_methods"].presence || item["contacts"]),
      "evidence" => normalize_evidence(item["evidence"]),
      "confidence" => confidence(item["confidence"])
    }
  end

  def normalize_company(item)
    name = compact(item["name"]).presence
    return nil unless name

    {
      "name" => name,
      "description" => compact(item["description"].presence || item["business_scope"], length: 280).presence,
      "industry" => compact(item["industry"]).presence,
      "project" => compact(item["project"]).presence,
      "people" => presence_array(item["people"]),
      "evidence" => normalize_evidence(item["evidence"].presence || item["source"]),
      "confidence" => confidence(item["confidence"])
    }
  end

  def normalize_project(item)
    name = compact(item["name"]).presence
    return nil unless name

    {
      "name" => name,
      "company" => compact(item["company"].presence || item["organization"]).presence,
      "description" => compact(item["description"], length: 320).presence,
      "stage_or_context" => compact(item["stage_or_context"].presence || item["context"]).presence,
      "people" => presence_array(item["people"]),
      "awards" => presence_array(item["awards"]),
      "contacts" => normalize_contacts(item["contacts"]),
      "evidence" => normalize_evidence(item["evidence"]),
      "confidence" => confidence(item["confidence"])
    }
  end

  def normalize_award(item)
    name = compact(item["name"].presence || item["award"] || item["rank"]).presence
    return nil unless name

    {
      "name" => name,
      "recipient_person" => compact(item["recipient_person"]).presence,
      "recipient_company_or_project" => compact(item["recipient_company_or_project"].presence || item["recipient"]).presence,
      "event_name" => compact(item["event_name"]).presence,
      "date" => compact(item["date"]).presence,
      "evidence" => normalize_evidence(item["evidence"]),
      "confidence" => confidence(item["confidence"])
    }
  end

  def normalize_contact(item)
    return nil unless item.is_a?(Hash)

    item = item.deep_stringify_keys
    value = compact(item["value"]).presence
    return nil unless value

    type = compact(item["type"]).presence&.downcase || "other"
    type = "other" unless CONTACT_TYPES.include?(type)

    {
      "type" => type,
      "value" => value,
      "belongs_to" => compact(item["belongs_to"].presence || item["person"] || item["company"] || item["project"]).presence,
      "context" => compact(item["context"], length: 240).presence,
      "evidence" => normalize_evidence(item["evidence"]),
      "confidence" => confidence(item["confidence"])
    }
  end

  def normalize_contacts(value)
    Array(value).filter_map do |contact|
      if contact.is_a?(Hash)
        normalize_contact(contact)
      elsif contact.present?
        normalize_contact({ "type" => "other", "value" => contact.to_s })
      end
    end.uniq { |contact| [ contact["type"], normalize_key(contact["value"]), normalize_key(contact["belongs_to"]) ] }
  end

  def normalize_evidence(value)
    raw = value.is_a?(Hash) ? [ value ] : Array(value)
    raw.filter_map do |item|
      if item.is_a?(Hash)
        item = item.deep_stringify_keys
        evidence = {
          "field" => compact(item["field"]).presence,
          "quote" => compact(item["quote"].presence || item["cited_text"], length: 500).presence,
          "source_url" => compact(item["source_url"].presence || item["url"]).presence,
          "source_title" => compact(item["source_title"].presence || item["title"]).presence
        }.compact
        evidence if evidence.present?
      elsif item.present?
        { "quote" => compact(item, length: 500) }
      end
    end.uniq
  end

  def confidence(value)
    value = value.to_s
    %w[high medium low].include?(value) ? value : "medium"
  end

  def legacy_intelligence(result)
    data = CATEGORIES.index_with { [] }

    Array(result["awards"]).each do |award|
      next unless award.is_a?(Hash)

      award = award.deep_stringify_keys
      project = award["project"].is_a?(Hash) ? award["project"].deep_stringify_keys : {}
      award_name = legacy_award_name(award)
      project_name = compact(project["name"]).presence
      organization = compact(project["organization"]).presence
      award_evidence = normalize_evidence(award["evidence"])

      if project_name
        data["projects"] << normalize_project({
          "name" => project_name,
          "company" => organization,
          "description" => project["description"],
          "stage_or_context" => award_name,
          "awards" => [ award_name ].compact,
          "evidence" => award_evidence,
          "confidence" => award_evidence.any? ? "high" : "medium"
        })
      end

      data["awards"] << normalize_award({
        "name" => award_name,
        "recipient_company_or_project" => project_name || organization,
        "event_name" => result.dig("event", "name"),
        "evidence" => award_evidence,
        "confidence" => award_evidence.any? ? "high" : "medium"
      }) if award_name.present?

      Array(award["people"]).each do |person|
        next unless person.is_a?(Hash)

        person = person.deep_stringify_keys
        contacts = legacy_person_contacts(person, award_evidence)
        company = current_employment(person).presence || organization
        evidence = normalize_evidence(person["evidence"]) + award_evidence
        data["people"] << normalize_person({
          "name" => person["name"],
          "role_or_title" => person["role"],
          "company" => company,
          "project" => project_name,
          "awards" => [ award_name ].compact,
          "contact_methods" => contacts,
          "evidence" => evidence,
          "confidence" => evidence.any? ? "high" : "medium"
        })
        contacts.each do |contact|
          data["contacts"] << normalize_contact(contact.merge(
            "belongs_to" => person["name"],
            "context" => [ award_name, project_name ].compact.join(" / ")
          ))
        end
      end
    end

    Array(result["companies"]).each do |company|
      data["companies"] << normalize_company(company) if company.is_a?(Hash)
    end

    CATEGORIES.index_with { |category| Array(data[category]).compact.uniq }
  end

  def legacy_award_name(award)
    [ award["category"], award["rank"].presence || award["award"] ].filter_map { |value| compact(value).presence }.join(" · ").presence
  end

  def legacy_person_contacts(person, fallback_evidence)
    contact = person["contact"].is_a?(Hash) ? person["contact"].deep_stringify_keys : {}
    {
      "email" => "email",
      "phone" => "phone",
      "website" => "website"
    }.filter_map do |field, type|
      value = compact(contact[field]).presence
      next unless value

      { "type" => type, "value" => value, "evidence" => normalize_evidence(contact["evidence"]).presence || fallback_evidence }
    end
  end

  def current_employment(person)
    Array(person["employment"]).filter_map do |item|
      next unless item.is_a?(Hash) && item["organization"].present?

      compact(item["organization"])
    end.first
  end
end
