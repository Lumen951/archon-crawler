class WechatAccount < Account
  def platform_name
    "微信公众号"
  end

  def platform_badge_class
    "bg-green-100 text-green-800"
  end

  def self.crawler_class
    Option.wechat_api_provider == "weread" ? WereadCrawler : WechatCrawler
  end

  # WeRead API 需要的 mpId (如 MP_WXS_xxx)
  def weread_mp_id
    metadata&.dig("weread_mp_id").presence || fakeid
  end
end
