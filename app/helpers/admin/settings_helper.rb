module Admin
  module SettingsHelper
    # 掩码 API key，只显示前4位和后4位
    # 例如: "abcdefgh12345678" -> "abcd****5678"
    def mask_api_key(key)
      return '' if key.blank?
      return key if key.length <= 8

      "#{key[0..3]}****#{key[-4..]}"
    end

    # 微信公众号平台会话有效期文案（唯一来源是 Option::WECHAT_MP_SESSION_TTL）
    def wechat_mp_session_ttl_label
      Option.wechat_mp_session_ttl_label
    end
  end
end
