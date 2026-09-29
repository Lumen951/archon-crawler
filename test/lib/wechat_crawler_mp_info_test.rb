require "test_helper"

class WechatCrawlerMpInfoTest < ActiveSupport::TestCase
  # 新版文章页: __biz 只出现在 JS 模板占位符里，真实值是 var biz = "..."
  NEW_STYLE_HTML = <<~HTML.freeze
    <html><body>
    <script>var biz = "MzA4NzEyNTE4OQ==" || "";</script>
    <script>var nickname = htmlDecode("博物");</script>
    <script>var ori_head_img_url = "http://wx.qlogo.cn/mmhead/test/132";</script>
    <script>var create_time = "1636254000" * 1;</script>
    <script>var url = "/s?__biz=${window.biz}&mid=${window.mid}";</script>
    </body></html>
  HTML

  # 旧版文章页: __biz 以 URL 参数形式内联（%3D%3D 为 base64 填充的 URL 编码）
  OLD_STYLE_HTML = <<~HTML.freeze
    <html><body>
    <script>var msg_link = "https://mp.weixin.qq.com/s?__biz=MzA4NzEyNTE4OQ%3D%3D&mid=1&idx=1";</script>
    <script>var nickname = htmlDecode("博物");</script>
    </body></html>
  HTML

  test "extract_mp_biz parses the var biz form on new-style pages" do
    assert_equal "MzA4NzEyNTE4OQ==", WechatCrawler.extract_mp_biz(NEW_STYLE_HTML)
  end

  test "extract_mp_biz keeps URL-parameter precedence and decodes padding" do
    assert_equal "MzA4NzEyNTE4OQ==", WechatCrawler.extract_mp_biz(OLD_STYLE_HTML)
  end

  test "extract_mp_biz returns nil when only JS placeholders exist" do
    html = '<script>var url = "/s?__biz=${window.biz}";</script>'
    assert_nil WechatCrawler.extract_mp_biz(html)
  end

  test "get_mp_info resolves account from a new-style article page" do
    stub_class_method(WechatCrawler, :fetch_article_page, ->(_url, crawl_task: nil) { NEW_STYLE_HTML }) do
      assert_equal [ {
        "id" => "MP_WXS_3087125189",
        "cover" => "http://wx.qlogo.cn/mmhead/test/132",
        "name" => "博物",
        "intro" => "",
        "updateTime" => 1_636_254_000
      } ], WechatCrawler.get_mp_info("https://mp.weixin.qq.com/s/Wl4obDCwrQtymxxGnP7CFw")
    end
  end

  test "get_mp_info returns empty when the page carries no usable biz" do
    html = "<html><body>正文</body></html>"
    stub_class_method(WechatCrawler, :fetch_article_page, ->(_url, crawl_task: nil) { html }) do
      assert_equal [], WechatCrawler.get_mp_info("https://mp.weixin.qq.com/s/abc")
    end
  end
end
