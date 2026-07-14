class RednoteAccount < Account
  def platform_name
    "小红书"
  end

  def platform_badge_class
    "bg-rose-100 text-rose-700"
  end

  def self.crawler_class
    RednoteCrawler
  end
end
