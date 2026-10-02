module E2EMock
  # 不走 HTTP、因而在 WebMock 覆盖范围之外的依赖，在 Ruby 层 stub：
  #   - WechatArticleBrowserFetcher（Ferrum 真浏览器）：E2E 里绝不允许拉起
  #     Chrome/触网，直接拒绝并给出明确指引——HTTP 层已为 /s/<slug> 提供正文
  #     fixture，会触发浏览器兜底说明 fixture 的 URL 形态不对。
  #   - TwitterApiClient（python3 子进程 + 真实 cookies）：回放 fixture JSON。
  module RubyStubs
    module BrowserFetcherStub
      def fetch(_url, crawl_task: nil)
        raise Error,
              "[E2EMock] 不应触发真实浏览器抓取：HTTP 层已提供文章正文 fixture。" \
              "若此错误出现，说明某篇文章 URL 不是 /s/<slug> 形式（或 HTTP mock 未生效）。"
      end
    end

    module TwitterStub
      def get_user_tweets(user_id, limit: 1)
        tweets = JSON.parse(E2EMock.fixture("twitter/user_tweets.json"))
        tweets = tweets.select { |t| t["author_id"].to_s == user_id.to_s } if tweets.first&.key?("author_id")
        limit.positive? ? tweets.first(limit) : tweets
      end

      def lookup_user(_screen_name)
        JSON.parse(E2EMock.fixture("twitter/users.json"))
      end

      def validate_cookies
        true
      end
    end

    class << self
      def apply!
        # lib/ 下的客户端不是 Zeitwerk 自动加载的，先显式加载再 prepend
        require "wechat_article_browser_fetcher"
        require "twitter_api_client"

        WechatArticleBrowserFetcher.singleton_class.prepend(BrowserFetcherStub)
        TwitterApiClient.singleton_class.prepend(TwitterStub)

        Rails.logger.info("[E2EMock] 已 stub：WechatArticleBrowserFetcher（拒绝真浏览器）、TwitterApiClient（fixture 回放）")
      end
    end
  end
end
