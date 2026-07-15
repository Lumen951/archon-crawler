class TwitterAccount < Account
  def platform_name
    "Twitter"
  end

  def platform_badge_class
    "bg-sky-100 text-sky-700"
  end

  def self.crawler_class
    TwitterCrawler
  end

  def twitter?
    true
  end
end
