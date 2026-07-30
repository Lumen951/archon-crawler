# frozen_string_literal: true

# Faraday middleware that caches HTTP responses to disk.
#
# Cache files are stored in tmp/responses/ as JSON, keyed by a SHA256 hash
# of the request method, URL, and body/query params.
#
# Usage:
#   conn = Faraday.new(url) do |f|
#     f.request :response_cache          # 24h TTL (default)
#     f.request :response_cache, ttl: 3600  # 1h TTL
#     f.adapter Faraday.default_adapter
#   end
#
# Bypass cache for a specific request:
#   conn.get(url, params, headers) do |req|
#     req.options.context = { nocache: true }
#   end
#
class ResponseCacheMiddleware < Faraday::Middleware
  DEFAULT_TTL = 24 * 60 * 60 # 24 hours
  CACHE_DIR = Rails.root.join("tmp", "responses")

  def initialize(app, ttl: DEFAULT_TTL)
    super(app)
    @ttl = ttl
  end

  def call(env)
    return @app.call(env) if skip_cache?(env)

    key = cache_key(env)
    cached = read_cache(key)

    if cached
      build_response(cached)
    else
      @app.call(env).tap do |response|
        write_cache(key, response) if response.success?
      end
    end
  end

  private

  def skip_cache?(env)
    return true if Rails.env.development?
    env.request.context&.dig(:nocache) == true
  end

  # Generate a cache key from method + URL + body/query params
  def cache_key(env)
    parts = [env.method.to_s.upcase, env.url.to_s]
    if env.body.present?
      parts << env.body.to_s
    end
    Digest::SHA256.hexdigest(parts.join("|"))
  end

  def cache_path(key)
    CACHE_DIR.join("#{key}.json")
  end

  def read_cache(key)
    path = cache_path(key)
    return nil unless path.exist?

    data = JSON.parse(path.read)
    return nil if Time.parse(data["cached_at"]) + @ttl < Time.current

    data
  rescue JSON::ParserError, Errno::ENOENT
    nil
  end

  def write_cache(key, response)
    FileUtils.mkdir_p(CACHE_DIR)

    data = {
      "cached_at" => Time.current.iso8601,
      "status"    => response.status,
      "headers"   => response.headers.to_hash,
      "body"      => response.body
    }

    cache_path(key).write(data.to_json)
  rescue StandardError => e
    Rails.logger.warn("ResponseCache write error: #{e.message}")
  end

  def build_response(cached)
    Faraday::Response.new(
      status: cached["status"],
      response_headers: Faraday::Utils::Headers.new(cached["headers"]),
      body: cached["body"]
    )
  end
end

Faraday::Request.register_middleware(response_cache: ResponseCacheMiddleware)
