require "test_helper"

class WechatCrawlerContentDownloadTest < ActiveSupport::TestCase
  setup do
    Option.delete_all
    @url = "https://mp.weixin.qq.com/s/abc123"
  end

  test "download_content falls back to the browser fetcher when blocked by environment verification" do
    blocked = ->(_url, crawl_task: nil) { raise WechatCrawler::DownloadError, "当前环境异常，需要验证" }
    browser_html = ->(_url, crawl_task: nil) { "<div id=\"js_content\">浏览器正文</div>" }

    stub_class_method(WechatCrawler, :fetch_article_page, blocked) do
      stub_class_method(WechatArticleBrowserFetcher, :fetch, browser_html) do
        assert_equal "浏览器正文", WechatCrawler.download_content(@url)
      end
    end
  end

  test "download_content does not fall back for deleted content" do
    deleted = ->(_url, crawl_task: nil) { raise WechatCrawler::DownloadError, "该内容已被发布者删除" }
    browser = ->(_url, crawl_task: nil) { flunk "删除的内容不应触发浏览器兜底" }

    stub_class_method(WechatCrawler, :fetch_article_page, deleted) do
      stub_class_method(WechatArticleBrowserFetcher, :fetch, browser) do
        error = assert_raises(WechatCrawler::DownloadError) { WechatCrawler.download_content(@url) }
        assert_match(/删除/, error.message)
      end
    end
  end

  test "browser fallback can be disabled" do
    Option.set("wechat_content_browser_fallback", "false")
    blocked = ->(_url, crawl_task: nil) { raise WechatCrawler::DownloadError, "当前环境异常，需要验证" }
    browser = ->(_url, crawl_task: nil) { flunk "开关关闭时不应触发浏览器兜底" }

    stub_class_method(WechatCrawler, :fetch_article_page, blocked) do
      stub_class_method(WechatArticleBrowserFetcher, :fetch, browser) do
        assert_raises(WechatCrawler::DownloadError) { WechatCrawler.download_content(@url) }
      end
    end
  end

  # 浏览器抓取仍未通过验证时，错误消息保留「…环境异常，需要验证」语义，
  # download_article_content 据此终止整批下载（平台级拦截，逐篇重试无意义）。
  test "download_article_content stops the batch when the browser path is still blocked" do
    blocked = ->(_url, crawl_task: nil) { raise WechatCrawler::DownloadError, "当前环境异常，需要验证" }
    still_blocked = ->(_url, crawl_task: nil) do
      raise WechatArticleBrowserFetcher::CaptchaRequiredError,
            "当前环境异常，需要验证：请在设置页「远程浏览器登录」完成环境验证后重试"
    end
    article = Article.new(url: @url)

    stub_class_method(WechatCrawler, :fetch_article_page, blocked) do
      stub_class_method(WechatArticleBrowserFetcher, :fetch, still_blocked) do
        error = assert_raises(WechatMpNativeApiClient::RateLimitError) do
          WechatCrawler.download_article_content(article, nil)
        end
        assert_match(/环境异常，需要验证/, error.message)
      end
    end
  end

  test "download_article_content succeeds through the browser fallback" do
    blocked = ->(_url, crawl_task: nil) { raise WechatCrawler::DownloadError, "当前环境异常，需要验证" }
    browser_html = ->(_url, crawl_task: nil) { "<div id=\"js_content\">浏览器正文</div>" }
    account = WechatAccount.create!(fakeid: "browser-fallback-test", nickname: "测试号")
    article = Article.create!(account: account, url: @url, title: "测试文章")

    stub_class_method(WechatCrawler, :fetch_article_page, blocked) do
      stub_class_method(WechatArticleBrowserFetcher, :fetch, browser_html) do
        assert WechatCrawler.download_article_content(article, nil)
        article.reload
        assert_equal "浏览器正文", article.content_html
      end
    end
  ensure
    article&.destroy
    account&.destroy
  end
end
