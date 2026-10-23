require "json"
require "time"
require "uri"

class SemanticScholarClient
  class FetchError < StandardError; end
  class NotFound < FetchError; end
  class TemporaryError < FetchError
    attr_reader :retry_after

    def initialize(message, retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end

  BASE_URL = "https://api.semanticscholar.org/graph/v1"
  MAX_BYTES = 2 * 1024 * 1024
  MAX_RETRIES = 2
  MAX_WAIT = 120

  def initialize(api_key: ENV["SEMANTIC_SCHOLAR_API_KEY"])
    @api_key = api_key
    @mutex = Mutex.new
    @connection = Faraday.new do |connection|
      connection.options.timeout = 15
      connection.options.open_timeout = 5
    end
  end

  def paper(arxiv_id)
    id = PaperImporter.new("https://arxiv.org/abs/#{arxiv_id}").parse_url.fetch(:external_id)
    data = fetch("paper/ARXIV:#{URI.encode_www_form_component(id)}", "title,externalIds,authors")
    unless data["paperId"].is_a?(String) && !data["paperId"].empty? &&
        data["title"].is_a?(String) && !data["title"].strip.empty? && data["authors"].is_a?(Array)
      raise FetchError, "Semantic Scholar returned invalid paper metadata"
    end
    external_ids = data["externalIds"]
    unless external_ids.is_a?(Hash) && external_ids["ArXiv"] == id
      raise FetchError, "Semantic Scholar did not verify the requested arXiv identifier"
    end
    authors = data["authors"].each_with_index.map do |entry, position|
      raise FetchError, "Semantic Scholar returned invalid authors" unless entry.is_a?(Hash)
      { "author_id" => author_id(entry["authorId"]), "name" => optional_text(entry["name"]), "position" => position }
    end
    evidence.merge("arxiv_id" => id, "paper_id" => data["paperId"], "title" => data["title"], "authors" => authors)
  end

  def author(id)
    unless id.is_a?(String) && id.match?(/\A\d{1,30}\z/)
      raise ArgumentError, "Invalid Semantic Scholar author identifier"
    end
    data = fetch("author/#{id}", "name,affiliations,homepage,externalIds")
    raise FetchError, "Semantic Scholar author identifier mismatch" unless data["authorId"] == id
    affiliations = data["affiliations"]
    unless affiliations.nil? || (affiliations.is_a?(Array) && affiliations.all? { |value| value.is_a?(String) })
      raise FetchError, "Semantic Scholar returned invalid affiliations"
    end
    ids = data["externalIds"]
    raise FetchError, "Semantic Scholar returned invalid external identifiers" unless ids.nil? || ids.is_a?(Hash)
    evidence.merge("author_id" => id, "name" => optional_text(data["name"]),
      "affiliations" => affiliations, "homepage" => optional_text(data["homepage"]), "external_ids" => ids)
  end

  private

  def evidence
    { "provider" => "semantic_scholar", "observed_at" => Time.now.utc.iso8601, "identity_verified" => false }
  end

  def optional_text(value)
    raise FetchError, "Semantic Scholar returned invalid text" unless value.nil? || value.is_a?(String)
    value.nil? || value.strip.empty? ? nil : value
  end

  def author_id(value)
    return if value.nil?
    raise FetchError, "Semantic Scholar returned invalid author identifier" unless value.is_a?(String) && value.match?(/\A\d{1,30}\z/)
    value
  end

  # This serializes one experimental client, not workers across the deployment.
  def fetch(path, fields)
    @mutex.synchronize do
      attempts = 0
      begin
        sleep 1
        request(path, fields)
      rescue TemporaryError => error
        wait = [ 60 * (2**attempts), error.retry_after.to_i ].max
        raise if attempts >= MAX_RETRIES || wait > MAX_WAIT
        attempts += 1
        sleep wait
        retry
      end
    end
  end

  def request(path, fields)
    body = +""
    response = @connection.get("#{BASE_URL}/#{path}", fields: fields) do |request|
      request.headers["Accept"] = "application/json"
      request.headers["x-api-key"] = @api_key unless @api_key.to_s.empty?
      request.options.on_data = lambda do |chunk, _size, _env|
        raise FetchError, "Semantic Scholar response exceeds 2 MB" if body.bytesize + chunk.bytesize > MAX_BYTES
        body << chunk
      end
    end
    case response.status
    when 200
      data = JSON.parse(body)
      raise FetchError, "Semantic Scholar returned invalid metadata" unless data.is_a?(Hash)
      data
    when 404
      raise NotFound, "Semantic Scholar has no record for this identifier"
    when 429, 500, 502, 503, 504
      raise TemporaryError.new("Semantic Scholar temporarily unavailable (HTTP #{response.status})",
        retry_after: retry_after(response.headers["retry-after"]))
    else
      raise FetchError, "Semantic Scholar request failed (HTTP #{response.status})"
    end
  rescue JSON::ParserError
    raise FetchError, "Semantic Scholar returned invalid JSON", cause: nil
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed
    raise TemporaryError, "Semantic Scholar connection failed or timed out", cause: nil
  rescue Faraday::SSLError
    raise FetchError, "Semantic Scholar TLS verification failed", cause: nil
  rescue Faraday::Error
    raise FetchError, "Semantic Scholar network request failed", cause: nil
  end

  def retry_after(value)
    return if value.to_s.empty?
    return value.to_i if value.match?(/\A\d+\z/)
    [ (Time.httpdate(value) - Time.now).ceil, 0 ].max
  rescue ArgumentError
    nil
  end
end
