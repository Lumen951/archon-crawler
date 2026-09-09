require "test_helper"
require "nokogiri"

class RssControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = WebsiteAccount.create!(fakeid: "example.com", nickname: "Example", metadata: { url: "https://example.com" })
    @other_account = WebsiteAccount.create!(fakeid: "other.example.com", nickname: "Other", metadata: { url: "https://other.example.com" })
    @page = @account.monitor_pages.create!(url: "https://example.com/news", title: "News", page_type: "news")
    @other_page = @other_account.monitor_pages.create!(url: "https://other.example.com/updates", title: "Updates", page_type: "updates")

    @change = @account.monitor_changes.create!(
      monitor_page: @page,
      summary: "A new announcement was published",
      refer_url: "https://example.com/news#announcement",
      change_type: "content_updated",
      importance: 8,
      relevance: 6,
      diff_added: 3,
      diff_removed: 1,
      created_at: 1.hour.ago
    )
    @other_change = @other_account.monitor_changes.create!(
      monitor_page: @other_page,
      summary: "An older update was published",
      change_type: "content_updated",
      importance: 3,
      relevance: 2,
      created_at: 2.hours.ago
    )
  end

  test "global monitor RSS includes recent changes" do
    get monitor_changes_rss_path

    assert_response :success
    assert_equal "application/rss+xml", response.media_type

    doc = Nokogiri::XML(response.body)
    items = doc.xpath("//item")
    assert_equal 2, items.length
    assert_equal "[Example] News", items.first.at_xpath("title").text
    assert_includes items.first.at_xpath("description").text, "A new announcement was published"
    assert_equal "https://example.com/news#announcement", items.first.at_xpath("link").text
    assert_equal monitor_change_url(@change), items.first.at_xpath("guid").text
  end

  test "important monitor RSS only includes important changes" do
    get important_monitor_changes_rss_path

    assert_response :success
    doc = Nokogiri::XML(response.body)
    assert_equal [monitor_change_url(@change)], doc.xpath("//item/guid").map(&:text)
  end

  test "website monitor RSS only includes that website changes" do
    get monitor_website_changes_rss_path(@account)

    assert_response :success
    doc = Nokogiri::XML(response.body)
    assert_equal [monitor_change_url(@change)], doc.xpath("//item/guid").map(&:text)
    assert_equal "Example - 官网变更", doc.at_xpath("//channel/title").text
  end

  test "page monitor RSS only includes that page changes" do
    get monitor_page_changes_rss_path(@page)

    assert_response :success
    doc = Nokogiri::XML(response.body)
    assert_equal [monitor_change_url(@change)], doc.xpath("//item/guid").map(&:text)
  end

  test "monitor RSS truncates change content" do
    long_summary = "内容" * 300
    change = @account.monitor_changes.create!(
      monitor_page: @page,
      summary: long_summary,
      refer_url: "https://example.com/long",
      created_at: 1.hour.ago
    )

    get monitor_changes_rss_path

    assert_response :success
    item = Nokogiri::XML(response.body).at_xpath("//item[guid='#{monitor_change_url(change)}']")
    content = item.at_xpath("description").text
    assert_includes content, "..."
    assert_operator content.lines.first.length, :<=, 504
  end

  test "monitor RSS supports XML format" do
    get monitor_changes_rss_path(format: :xml)

    assert_response :success
    assert_equal "application/xml", response.media_type
    assert_equal 2, Nokogiri::XML(response.body).xpath("//item").length
  end

  test "monitor RSS routes do not fall through to account RSS" do
    get "/rss/monitor/changes"

    assert_response :success
    assert_includes response.body, "官网变更"
  end

  test "monitor RSS defaults to the last seven days" do
    old_change = @account.monitor_changes.create!(
      monitor_page: @page,
      summary: "Old change",
      importance: 9,
      created_at: 8.days.ago
    )

    get monitor_changes_rss_path

    assert_response :success
    ids = Nokogiri::XML(response.body).xpath("//item/guid").map(&:text)
    assert_includes ids, monitor_change_url(@change)
    assert_not_includes ids, monitor_change_url(old_change)
  end

  test "monitor RSS is limited to one hundred changes" do
    101.times do |index|
      @account.monitor_changes.create!(
        monitor_page: @page,
        summary: "Change #{index}",
        created_at: (index + 1).minutes.ago
      )
    end

    get monitor_changes_rss_path

    assert_response :success
    assert_equal 100, Nokogiri::XML(response.body).xpath("//item").length
  end

  test "missing website account returns not found" do
    get monitor_website_changes_rss_path(-1)

    assert_response :not_found
    assert_equal "Website account not found", response.body
  end

  test "global monitor pages RSS lists pages with the most recently changed first" do
    @page.update!(last_changed_at: 1.hour.ago)
    @other_page.update!(last_changed_at: 2.hours.ago)

    get monitor_pages_rss_path

    assert_response :success
    assert_equal "application/rss+xml", response.media_type

    doc = Nokogiri::XML(response.body)
    guids = doc.xpath("//item/guid").map(&:text)
    assert_equal [monitor_page_url(@page), monitor_page_url(@other_page)], guids
    assert_equal "[Example] News", doc.at_xpath("//item/title").text
    assert_equal "https://example.com/news", doc.at_xpath("//item/link").text
    assert_includes doc.at_xpath("//item/description").text, "类型: 新闻"
  end

  test "monitor pages RSS orders never-fetched pages after changed ones" do
    @page.update!(last_changed_at: 1.hour.ago)
    @other_page.update_column(:created_at, 3.days.ago) # discovered long ago, never fetched

    get monitor_pages_rss_path

    doc = Nokogiri::XML(response.body)
    guids = doc.xpath("//item/guid").map(&:text)
    assert_equal monitor_page_url(@page), guids.first
    assert_equal monitor_page_url(@other_page), guids.last
  end

  test "monitor pages RSS includes the current baseline content" do
    @page.monitor_page_versions.create!(
      content_hash: MonitorPageVersion.digest("baseline content"),
      content: "baseline content",
      captured_at: Time.current,
      fetched_via: "http"
    )
    version = @page.monitor_page_versions.first
    @page.update!(current_version_id: version.id)

    get monitor_pages_rss_path

    assert_response :success
    assert_includes Nokogiri::XML(response.body).at_xpath("//item[guid='#{monitor_page_url(@page)}']/description").text, "baseline content"
  end

  test "website monitor pages RSS only includes that website's pages" do
    get monitor_website_pages_rss_path(@account)

    assert_response :success
    doc = Nokogiri::XML(response.body)
    assert_equal [monitor_page_url(@page)], doc.xpath("//item/guid").map(&:text)
    assert_equal "Example - 官网监控页面", doc.at_xpath("//channel/title").text
  end

  test "monitor pages RSS is limited to one hundred pages" do
    101.times do |index|
      @account.monitor_pages.create!(url: "https://example.com/p/#{index}", title: "Page #{index}", page_type: "news")
    end

    get monitor_pages_rss_path

    assert_response :success
    assert_equal 100, Nokogiri::XML(response.body).xpath("//item").length
  end

  test "monitor pages RSS supports XML format" do
    get monitor_pages_rss_path(format: :xml)

    assert_response :success
    assert_equal "application/xml", response.media_type
    assert_equal 2, Nokogiri::XML(response.body).xpath("//item").length
  end

  test "missing website account returns not found for pages feed" do
    get monitor_website_pages_rss_path(-1)

    assert_response :not_found
    assert_equal "Website account not found", response.body
  end
end
