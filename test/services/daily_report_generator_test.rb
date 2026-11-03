require "test_helper"

class DailyReportGeneratorTest < ActiveSupport::TestCase
  setup do
    @date = Date.new(2026, 11, 2)
    @report = DailyReport.create!(
      report_date: @date,
      window_start: Time.zone.local(2026, 11, 2),
      window_end: Time.zone.local(2026, 11, 3)
    )
    @account = WebsiteAccount.create!(
      nickname: "活动行",
      fakeid: "https://events.example.test",
      metadata: { "monitoring_group" => "event_sources" }
    )
    @article = Article.create!(
      account: @account,
      title: "具身智能活动",
      url: "https://events.example.test/event/1",
      created_at: Time.zone.local(2026, 11, 3, 8, 20),
      content_markdown: "活动时间：11月10日。地点：上海。"
    )
    @paper = Paper.create!(title: "机器人研究", abstract: "技术摘要", created_at: Time.zone.local(2026, 11, 2, 12))
    PaperSource.create!(paper: @paper, provider: "arxiv", external_id: "2601.12345", canonical_url: "https://arxiv.org/abs/2601.12345")
  end

  test "includes previous-day records and already imported event articles from report morning" do
    captured_prompt = nil
    llm = Object.new
    llm.define_singleton_method(:generate_json) do |prompt|
      captured_prompt = prompt
      { "items" => [
        { "source_type" => "article", "source_id" => @article.id, "kind" => "event", "event_name" => "具身智能活动" },
        { "source_type" => "paper", "source_id" => @paper.id, "kind" => "technical", "summary" => "研究摘要" },
        { "source_type" => "paper", "source_id" => 999_999, "kind" => "technical", "summary" => "无效来源" }
      ] }
    end

    result = nil
    travel_to Time.zone.local(2026, 11, 3, 9, 0) do
      result = DailyReportGenerator.new(llm: llm).call(@report)
    end

    assert_includes captured_prompt, "具身智能活动"
    assert_includes captured_prompt, "机器人研究"
    assert_equal [ @article.id, @paper.id ], result.fetch("items").map { |item| item.fetch("source_id") }
    assert_equal "https://events.example.test/event/1", result.fetch("items").first.fetch("url")
    assert_equal 1, @report.reload.article_count
    assert_equal 1, @report.paper_count
  end

  test "returns empty items without calling LLM when no sources exist" do
    Article.delete_all
    PaperSource.delete_all
    Paper.delete_all
    llm = Object.new
    llm.define_singleton_method(:generate_json) { |_prompt| raise "should not be called" }

    assert_equal({ "items" => [] }, DailyReportGenerator.new(llm: llm).call(@report))
  end

  test "rejects invalid model response shape" do
    llm = Object.new
    llm.define_singleton_method(:generate_json) { |_prompt| { "entries" => [] } }

    assert_raises(DailyReportGenerator::GenerationError) do
      DailyReportGenerator.new(llm: llm).call(@report)
    end
  end
end
