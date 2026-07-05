module Admin
  module SettingsHelper
    # 掩码 API key，只显示前4位和后4位
    # 例如: "abcdefgh12345678" -> "abcd****5678"
    def mask_api_key(key)
      return '' if key.blank?
      return key if key.length <= 8

      "#{key[0..3]}****#{key[-4..]}"
    end
  end
end
