# 扫码登录平台注册表。
#
# 微信读书（weread）与微信公众号平台（wechat_mp）的扫码登录流程一致：
#   取二维码 → 轮询扫码状态 → 成功后落库。
# 差异（HTTP 传输、状态码语义、落库位置）由各自的 QrLogin::Base 子类吸收，
# 调用方（设置页控制器、飞书提醒 Job、飞书卡片回调）只面向统一接口。
module QrLogin
  PROVIDERS = {
    "weread" => "QrLogin::Weread",
    "wechat_mp" => "QrLogin::WechatMp"
  }.freeze

  class Error < StandardError; end

  def self.keys
    PROVIDERS.keys
  end

  def self.all
    keys.map { |key| find(key) }
  end

  def self.find(key)
    class_name = PROVIDERS[key.to_s]
    raise Error, "未知的扫码登录平台: #{key}" if class_name.nil?

    class_name.constantize
  end

  # 按飞书卡片按钮的 action 值反查平台（例如 "weread_login" → QrLogin::Weread）
  def self.find_by_card_action(action)
    return nil if action.blank?

    all.find { |provider| provider.card_action == action.to_s }
  end
end
