# frozen_string_literal: true

# Faraday middleware that enforces rate limiting before each HTTP request.
#
# Usage (when building a Faraday connection):
#   limiter = RateLimiter.new(60, 60)
#   conn = Faraday.new(url) do |f|
#     f.request :rate_limiter, limiter
#     f.adapter Faraday.default_adapter
#   end
#
class RateLimiterMiddleware < Faraday::Middleware
  def initialize(app, rate_limiter)
    super(app)
    @rate_limiter = rate_limiter
  end

  def call(env)
    @rate_limiter.wait
    @app.call(env)
  end
end

Faraday::Request.register_middleware(rate_limiter: RateLimiterMiddleware)
