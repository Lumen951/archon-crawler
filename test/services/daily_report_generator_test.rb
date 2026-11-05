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
    paper_id = @paper.id
    llm.define_singleton_method(:generate) do |prompt|
      captured_prompt = prompt
      "# 每日研究简报\n\n具身智能活动\n\n机器人研究 [paper:#{paper_id}]"
    end

    result = nil
    travel_to Time.zone.local(2026, 11, 3, 9, 0) do
      result = DailyReportGenerator.new(llm: llm).call(@report)
    end

    assert_includes captured_prompt, "具身智能活动"
    assert_includes captured_prompt, "机器人研究"
    assert_includes result, "机器人研究"
    assert_equal 1, @report.reload.article_count
    assert_equal 1, @report.paper_count
  end

  test "returns empty items without calling LLM when no sources exist" do
    Article.delete_all
    PaperSource.delete_all
    Paper.delete_all
    llm = Object.new
    llm.define_singleton_method(:generate) { |_prompt| raise "should not be called" }

    assert_includes DailyReportGenerator.new(llm: llm).call(@report), "当天没有新增内容"
  end

  test "rejects unknown and missing source references" do
    [ "日报 [paper:999999999]", "日报没有来源" ].each do |response|
      llm = Object.new
      llm.define_singleton_method(:generate) { |_prompt| response }
      assert_raises(DailyReportGenerator::GenerationError) do
        DailyReportGenerator.new(llm: llm).call(@report)
      end
    end
  end

  test "rejects empty model response" do
    llm = Object.new
    llm.define_singleton_method(:generate) { |_prompt| "" }

    assert_raises(DailyReportGenerator::GenerationError) do
      DailyReportGenerator.new(llm: llm).call(@report)
    end
  end
end
