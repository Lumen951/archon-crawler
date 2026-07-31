require 'faraday'
require 'faraday/retry'
require 'rate_limiter'
require 'rate_limiter_middleware'
require 'response_cache_middleware'
require 'crawler_api_key_error'

# Alternative WeChat article API client using the Dajiala API (dajiala.com).
# Provides the same public interface as WechatApiClient so the crawler can
# switch between providers via Option.wechat_api_provider.
#
# Dajiala endpoints:
#   POST /fbmain/monitor/v3/history_by_ghid — historical articles by ghid/fakeid (paginated)
#   GET  /fbmain/monitor/v3/article_detail  — article content by URL
#   POST /fbmain/monitor/v3/avatar_type     — account basic info (avatar, type, description)
class DajialaApiClient
  BASE_URL = "https://www.dajiala.com"

  class ApiError < StandardError; end

  class ApiKeyMissingError < ApiError
    include CrawlerApiKeyError
  end

  class ApiRateLimitError < ApiError; end

  # Rate limiter: 30 requests per minute (conservative default for Dajiala)
  RATE_LIMITER = RateLimiter.new(30, 60)

  def self.connection
    @connection ||= Faraday.new(url: BASE_URL) do |f|
      f.request :response_cache
      f.request :json
      f.request :rate_limiter, RATE_LIMITER
      f.request :retry, max: 3, interval: 2, backoff_factor: 2,
                exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      f.adapter Faraday.default_adapter
    end
  end

  def self.api_key
    key = Option.dajiala_api_key
    raise ApiKeyMissingError, "未配置 Dajiala API 密钥" unless key.present?
    key
  end

  # Fetch historical articles for a WeChat channel by ghid (原始id/fakeid).
  #
  # Supports pagination via begin_offset (pass the PagingInfo.Offset from the
  # previous response). Each page returns ~10 posting rounds (each round has
  # 1-8 articles).
  #
  # Returns a Hash matching WechatApiClient format:
  #   { "articles" => [...], "dajiala_offset" => "next_offset_string" }
  # The caller should pass dajiala_offset back as begin_offset for the next page.
  def self.get_articles(nickname, begin_offset: 0, size: 20)
    payload = {
      nickname: nickname,
      key: api_key,
      url: "",
      offset: begin_offset.is_a?(String) ? begin_offset : "",
      verifycode: ""
    }

    response = connection.post('/fbmain/monitor/v3/history_by_ghid') do |req|
      req.body = payload.to_json
    end

    resp = handle_response(response)

    # Extract articles from nested structure:
    # resp["MsgList"]["Msg"] => array of posting rounds
    # Each round has AppMsg.DetailInfo => array of articles
    msg_list = resp.dig("MsgList", "Msg") || []
    articles = msg_list.flat_map do |msg|
      details = msg.dig("AppMsg", "DetailInfo") || []
      details.map do |detail|
        {
          "link"        => detail["ContentUrl"],
          "title"       => detail["Title"],
          "author_name" => resp.dig("AccountInfo", "NickName") || "",
          "digest"      => detail["Digest"],
          "cover"       => detail["CoverImgUrl"] || detail["CoverImgUrl_1_1"],
          "create_time" => detail["send_time"] || msg.dig("AppMsg", "BaseInfo", "CreateTime")
        }
      end
    end

    # Pagination info
    paging = resp["PagingInfo"] || {}
    offset = paging["Offset"].to_s

    result = { "articles" => articles }
    result["dajiala_offset"] = offset if offset.present?
    result["dajiala_end"] = paging["IsEnd"] == 1
    result
  end

  # Download article content (HTML) by URL via Dajiala article_detail API.
  #
  # Returns raw HTML string (same as WechatApiClient.download_content).
  def self.download_content(url, format: 'html')
    response = connection.get('/fbmain/monitor/v3/article_detail') do |req|
      req.params = { url: url, key: api_key, mode: "1" }
    end

    data = handle_response(response)
    data["content"] || ""
  end

  # Fetch basic account info (avatar, type, description) by account name/原始id/wxid.
  #
  # Returns a Hash with account details:
  #   { "name" => "人民日报", "biz" => "MjM5MjAxNDM4MA==", "wxid" => "rmrbwx",
  #     "type" => "订阅号", "avatar" => "http://...", "desc" => "参与、沟通、记录时代。" }
  def self.get_account_info(name)
    payload = {
      name: name,
      key: api_key,
      verifycode: ""
    }

    response = connection.post('/fbmain/monitor/v3/avatar_type') do |req|
      req.body = payload.to_json
    end

    handle_response(response)
  end

  # Validate that the API key works by making a lightweight request.
  # Dajiala has no dedicated validation endpoint, so we attempt a minimal
  # history_by_ghid call. Returns true if successful.
  def self.validate_key
    payload = {
      ghid: "gh_test",
      key: api_key,
      url: "",
      offset: "",
      verifycode: ""
    }

    response = connection.post('/fbmain/monitor/v3/history_by_ghid') do |req|
      req.body = payload.to_json
    end

    handle_response(response)
    true
  rescue ApiKeyMissingError
    false
  rescue ApiError, ApiRateLimitError
    # API returned an error, but the key itself was accepted
    true
  end

  private

  def self.handle_response(response)
    body = response.body
    if body.encoding == Encoding::ASCII_8BIT
      body = body.dup.force_encoding(Encoding::UTF_8)
    end

    case response.status
    when 200
      parsed = JSON.parse(body)
      code = parsed["code"]
      if code != 0
        msg = parsed["msg"] || "未知错误"
        case code
        when -1, 111
          raise ApiRateLimitError, "Dajiala 频率限制 (code=#{code})：#{msg}"
        when 113, 10002, 20001
          raise ApiKeyMissingError, "Dajiala 鉴权失败 (code=#{code})：#{msg}"
        else
          raise ApiError, "Dajiala API 错误 (code=#{code})：#{msg}"
        end
      end
      parsed
    when 401, 403
      raise ApiKeyMissingError, "Dajiala API 密钥无效：#{response.status}"
    when 429
      raise ApiRateLimitError, "Dajiala 超出速率限制：#{response.status}"
    else
      raise ApiError, "Dajiala API 错误：#{response.status} - #{body}"
    end
  rescue JSON::ParserError => e
    raise ApiError, "Dajiala 无效的 JSON 响应：#{e.message}"
  end
end
