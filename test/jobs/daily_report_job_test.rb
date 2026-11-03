require "test_helper"

class DailyReportJobTest < ActiveSupport::TestCase
  test "generates the previous Beijing calendar day once" do
    travel_to Time.zone.local(2026, 11, 3, 9, 0) do
      stub_class_method(DailyReportGenerator, :new, -> { fake_generator({ "items" => [] }) }) do
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
      stub_class_method(DailyReportGenerator, :new, -> { fake_generator_error }) do
        assert_raises(DailyReportGenerator::GenerationError) { DailyReportJob.perform_now }
      end

      report = DailyReport.find_by!(report_date: Date.new(2026, 11, 2))
      assert report.failed?
      assert_equal "LLM 不可用", report.error_message
    end
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
