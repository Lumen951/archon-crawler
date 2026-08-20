# frozen_string_literal: true

module Tools
  # 微信读书登录会话缓存：按 API Key id 命名空间存储当前登录 uuid。
  #
  # 让 weread_login_status 可以在不传 uuid 的情况下查到最近一次会话，
  # 从而避免 uuid 进入 mcp_tool_calls.arguments 被原文落库。
  module WereadLoginSession
    TTL = 5.minutes

    def self.key(api_key_id) = "weread_login_uuid:api_key:#{api_key_id}"

    def self.store(api_key_id, uuid)
      Rails.cache.write(key(api_key_id), uuid, expires_in: TTL)
    end

    def self.fetch(api_key_id)
      Rails.cache.read(key(api_key_id))
    end

    def self.clear(api_key_id)
      Rails.cache.delete(key(api_key_id))
    end
  end
end
