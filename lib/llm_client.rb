require "faraday"
require "faraday/retry"
require "json"

# Thin client for the OpenAI-compatible Responses API, called through the
# MiraclePlus proxy. Configuration comes from Option (openai_api_key /
# openai_model / openai_proxy_url) — never hardcode the key.
#
# The Responses API returns text nested under output[].content[]; extract_text
# skips reasoning items and pulls the first non-empty output_text/text block.
class LlmClient
  class ApiError < StandardError; end

  class ApiKeyMissingError < ApiError
    include CrawlerApiKeyError
  end

  def initialize(api_key: Option.openai_api_key, model: Option.openai_model, base_url: Option.openai_proxy_url)
    @api_key = api_key
    @model = model
    @base_url = base_url
  end

  def self.configured?
    Option.openai_api_key.present?
  end

  # Send a prompt and parse the reply as JSON. Strips accidental ```json fences.
  def generate_json(prompt)
    JSON.parse(strip_fences(generate(prompt)))
  end

  def generate(prompt)
    raise ApiKeyMissingError, "未配置 OpenAI API 密钥（openai_api_key）" if @api_key.blank?

    response = connection.post("responses") do |req|
      req.headers["Authorization"] = "Bearer #{@api_key}"
      req.headers["Content-Type"] = "application/json"
      req.body = JSON.generate(model: @model, input: prompt)
    end

    unless response.success?
      raise ApiError, "LLM API 错误 #{response.status}: #{response.body.to_s[0, 500]}"
    end

    extract_text(JSON.parse(response.body))
  end

  private

  def connection
    @connection ||= Faraday.new(url: ensure_trailing_slash(@base_url)) do |f|
      f.request :retry, max: 2, interval: 1, backoff_factor: 2,
                        exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      f.options.timeout = 120
      f.options.open_timeout = 20
      f.adapter Faraday.default_adapter
    end
  end

  def ensure_trailing_slash(url)
    url.to_s.end_with?("/") ? url : "#{url}/"
  end

  def extract_text(body)
    text = Array(body["output"])
             .flat_map { |item| Array(item["content"]) }
             .select { |content| %w[output_text text].include?(content["type"]) }
             .map { |content| content["text"].to_s }
             .find { |value| !value.strip.empty? }

    raise ApiError, "LLM 未返回文本: #{body.inspect[0, 500]}" unless text

    text
  end

  def strip_fences(text)
    text.to_s
        .gsub(/\A```json\s*/, "")
        .gsub(/\A```\s*/, "")
        .gsub(/\s*```\z/, "")
        .strip
  end
end
