class WechatAccount < Account
  def platform_name
    "微信公众号"
  end

  def platform_badge_class
    "bg-green-100 text-green-800"
  end
end
