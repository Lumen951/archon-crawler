require "test_helper"

class DailyReportJobTest < ActiveSupport::TestCase
  test "generates the previous Beijing calendar day once" do
    travel_to Time.zone.local(2026, 11, 3, 9, 0) do
      generator = fake_generator("# 每日研究简报\n\n无新增内容")
      stub_class_method(DailyReportGenerator, :new, -> { generator }) do
        DailyReportJob.perform_now
        DailyReportJob.perform_now
      end

      report = DailyReport.find_by!(report_date: Date.new(2026, 11, 2))
      assert report.completed?
      assert_equal Time.zone.local(2026, 11, 2), report.window_start
      assert_equal Time.zone.local(2026, 11, 3), report.window_end
      assert_equal 1, DailyReport.count
    end
  end

  test "records generation failure and re-raises it" do
    travel_to Time.zone.local(2026, 11, 3, 9, 0) do
      generator = fake_generator_error
      stub_class_method(DailyReportGenerator, :new, -> { generator }) do
        assert_raises(DailyReportGenerator::GenerationError) { DailyReportJob.perform_now }
      end

      report = DailyReport.find_by!(report_date: Date.new(2026, 11, 2))
      assert report.failed?
      assert_includes report.error_message, "日报生成或保存失败"
      refute_includes report.error_message, "LLM 不可用"
    end
  end

  test "repairs a missing file without generating another report" do
    report = DailyReport.create!(report_date: Date.new(2026, 11, 1),
      window_start: Time.zone.local(2026, 11, 1), window_end: Time.zone.local(2026, 11, 2),
      status: :completed, markdown_content: "# 已保存日报")
    writes = 0
    stub_class_method(DailyReportGenerator, :new, -> { raise "must not regenerate" }) do
      stub_class_method(DailyReportMarkdownStore, :write!, ->(_report) { writes += 1 }) do
        DailyReportJob.perform_now(report.report_date)
      end
    end
    assert_equal 1, writes
    assert report.reload.completed?
  end

  test "retains generated content after file failure and retries only the write" do
    date = Date.new(2026, 11, 1)
    generator = fake_generator("# 保存的正文")
    stub_class_method(DailyReportGenerator, :new, -> { generator }) do
      stub_class_method(DailyReportMarkdownStore, :write!, ->(_report) { raise IOError, "private error" }) do
        assert_raises(DailyReportGenerator::GenerationError) { DailyReportJob.perform_now(date) }
      end
    end
    report = DailyReport.find_by!(report_date: date)
    assert report.failed?
    assert_equal "# 保存的正文", report.markdown_content
    refute_includes report.error_message, "private error"
    stub_class_method(DailyReportGenerator, :new, -> { raise "must not regenerate" }) do
      DailyReportJob.perform_now(date)
    end
    assert report.reload.completed?
    assert_equal report.markdown_content, File.read(report.markdown_path)
  end

  private

  def fake_generator(result)
    Struct.new(:result) do
      def call(_report)
        result
      end
    end.new(result)
  end

  def fake_generator_error
    Object.new.tap do |generator|
      generator.define_singleton_method(:call) { |_report| raise DailyReportGenerator::GenerationError, "LLM 不可用" }
    end
  end
end
