class EventResearch::ResultDiff
  def self.call(previous, current)
    new(previous, current).call
  end

  def initialize(previous, current)
    @previous = previous.is_a?(Hash) ? previous : {}
    @current = current.is_a?(Hash) ? current : {}
  end

  def call
    {
      "awards" => additions("awards"),
      "companies" => additions("companies"),
      "people" => people_additions,
      "updates" => updates
    }.tap { |diff| diff["empty"] = diff.values_at("awards", "companies", "people", "updates").all?(&:empty?) }
  end

  private

  def additions(key)
    previous = Array(@previous[key]).map { |item| [ identity(item), item ] }.to_h
    Array(@current[key]).select { |item| item.is_a?(Hash) && !previous.key?(identity(item)) }
  end

  def people_additions
    previous = people_with_context(@previous).to_h { |person| [ person[:key], person ] }
    people_with_context(@current).reject { |person| previous.key?(person[:key]) }.map { |person| person[:value] }
  end

  def updates
    previous = flattened_entities(@previous)
    flattened_entities(@current).filter_map do |key, value|
      old = previous[key]
      next unless old.is_a?(Hash) && value.is_a?(Hash)
      next unless newly_populated?(old, value)

      { "key" => key, "before" => old, "after" => value }
    end
  end

  def people_with_context(result)
    Array(result["awards"]).flat_map do |award|
      context = identity(award)
      Array(award["people"]).filter_map do |person|
        next unless person.is_a?(Hash) && person["name"].present?
        { key: "#{context}|#{normalize(person['name'])}", value: person.merge("_award" => award["rank"].presence || award["award"]) }
      end
    end
  end

  def flattened_entities(result)
    entities = {}
    Array(result["awards"]).each { |award| entities[identity(award)] = award if award.is_a?(Hash) }
    Array(result["companies"]).each { |company| entities["company|#{normalize(company['name'])}"] = company if company.is_a?(Hash) && company["name"].present? }
    people_with_context(result).each { |person| entities["person|#{person[:key]}"] = person[:value] }
    entities
  end

  def newly_populated?(old, new)
    new.any? { |key, value| blank?(old[key]) && !blank?(value) }
  end

  def identity(item)
    return "unknown|#{item.object_id}" unless item.is_a?(Hash)
    [ item["rank"], item["award"], item["category"], item.dig("project", "name"), item.dig("project", "organization"), item["name"] ].map { |value| normalize(value) }.join("|")
  end

  def normalize(value)
    value.to_s.downcase.gsub(/\s+/, "").strip
  end

  def blank?(value)
    value.blank? || (value.is_a?(Array) && value.empty?)
  end
end
