require "json"
require "open3"

# Client for fetching Twitter tweets via the twitter-api-client Python library.
# Calls the Python CLI wrapper (bin/twitter_fetch.py) which handles authentication
# and GraphQL response parsing.
#
# Authentication uses cookies set via environment variables:
#   TWITTER_CT0         - CSRF token cookie
#   TWITTER_AUTH_TOKEN  - Session auth token cookie
#
# Configure these in admin/settings as `twitter_ct0`, `twitter_auth_token`.
class TwitterApiClient
  FETCH_SCRIPT = Rails.root.join("bin", "twitter_fetch.py").to_s

  class ApiError < StandardError
  end

  class ApiKeyMissingError < ApiError
    include CrawlerApiKeyError
  end

  class ApiRateLimitError < ApiError
  end

  # Fetch tweets for a user by their numeric Twitter user ID.
  # @param user_id [String, Integer] the Twitter user ID (numeric)
  # @param limit [Integer] max tweets to fetch (0 = all available)
  # @return [Array<Hash>] normalized tweet objects
  def self.get_user_tweets(user_id, limit: 1)
    env = build_env
    cmd = ["python3", FETCH_SCRIPT, user_id.to_s]
    cmd += ["--limit", limit.to_s] if limit > 0

    stdout, stderr, status = Open3.capture3(env, *cmd)

    # Log stderr (progress bars, warnings) for debugging
    if stderr.present?
      Rails.logger.debug("TwitterApiClient stderr: #{stderr.strip.truncate(500)}")
    end

    unless status.success?
      error_msg = stderr.strip
      if error_msg.include?("TWITTER_CT0") || error_msg.include?("TWITTER_AUTH_TOKEN")
        raise ApiKeyMissingError, "Twitter cookies 未配置：#{error_msg}"
      end
      raise ApiError, "Twitter API 调用失败 (exit #{status.exitstatus})：#{error_msg}"
    end

    tweets = JSON.parse(stdout)
    tweets || []
  rescue JSON::ParserError => e
    raise ApiError, "Twitter API 返回无效 JSON：#{e.message} — stdout: #{stdout.to_s.truncate(200)}"
  end

  # Look up a Twitter user by screen name (username).
  # @param screen_name [String] the screen name (without @)
  # @return [Array<Hash>] user info with rest_id, screen_name, name, etc.
  def self.lookup_user(screen_name)
    env = build_env
    cmd = ["python3", FETCH_SCRIPT, "--lookup", screen_name]

    stdout, stderr, status = Open3.capture3(env, *cmd)

    unless status.success?
      error_msg = stderr.strip
      if error_msg.include?("TWITTER_CT0") || error_msg.include?("TWITTER_AUTH_TOKEN")
        raise ApiKeyMissingError, "Twitter cookies 未配置：#{error_msg}"
      end
      raise ApiError, "Twitter API 调用失败 (exit #{status.exitstatus})：#{error_msg}"
    end

    users = JSON.parse(stdout)
    users || []
  rescue JSON::ParserError => e
    raise ApiError, "Twitter API 返回无效 JSON：#{e.message}"
  end

  # Validate that the configured cookies are working.
  # Returns true if valid, false if unauthorized, nil on network/unknown error.
  def self.validate_key
    get_user_tweets(44196397, limit: 1)  # @elonmusk — just a test fetch
    true
  rescue ApiKeyMissingError
    false
  rescue => e
    Rails.logger.warn("Twitter API key validation error: #{e.message}")
    nil
  end

  private

  def self.build_env
    ct0 = Option.get("twitter_ct0")
    auth_token = Option.get("twitter_auth_token")

    raise ApiKeyMissingError, "未配置 Twitter cookies（twitter_ct0 / twitter_auth_token）" unless ct0.present? && auth_token.present?

    {
      "TWITTER_CT0" => ct0,
      "TWITTER_AUTH_TOKEN" => auth_token,
      # Clear proxy env vars to avoid SOCKS proxy issues with httpx
      "HTTP_PROXY" => nil, "HTTPS_PROXY" => nil, "ALL_PROXY" => nil,
      "http_proxy" => nil, "https_proxy" => nil, "all_proxy" => nil
    }
  end
end
