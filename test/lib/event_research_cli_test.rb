require "test_helper"
require "stringio"
require "tmpdir"
require_relative "../../script/event_research"

# CLI 入口（script/event_research.rb）专属的测试：结果落盘、退化保护、日志格式。
# 调研流程本身的测试在 test/lib/event_research_test.rb。
# 脚本文件有 __FILE__ == $PROGRAM_NAME 入口守卫，require 它是安全的；
# config/environment 已由 test_helper 加载过，require 相同路径不会二次初始化。
class EventResearchCliTest < ActiveSupport::TestCase
  def setup
    @tmpdir = Dir.mktmpdir("event-research-cli-test")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  # --- CliSink ------------------------------------------------------------

  test "stdout 每行带时间戳（warn/error 的缩进保留在其后），run.log 仍是完整 iso8601" do
    stdout = StringIO.new
    sink = EventResearch::CliSink.new(File.join(@tmpdir, "run.log"), stdout: stdout)
    reporter = EventResearch::Reporter.new(sink)
    reporter.info("开始")
    reporter.warn("注意")
    reporter.error("失败")
    reporter.close

    lines = stdout.string.lines.map(&:chomp)
    assert_match(/\A\[\d{2}:\d{2}:\d{2}\] 开始\z/, lines[0])
    assert_match(/\A\[\d{2}:\d{2}:\d{2}\] {3}! 注意\z/, lines[1])
    assert_match(/\A\[\d{2}:\d{2}:\d{2}\] {3}!! 失败\z/, lines[2])

    # 文件里保留完整时间戳（含日期与时区），终端里的 HH:MM:SS 只是给人看进度用
    log = File.read(File.join(@tmpdir, "run.log"))
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\S+ \[INFO\] 开始\z/, log.lines.first.chomp)
  end

  test "debug 不刷屏但写进 run.log" do
    stdout = StringIO.new
    sink = EventResearch::CliSink.new(File.join(@tmpdir, "run.log"), stdout: stdout)
    reporter = EventResearch::Reporter.new(sink)
    reporter.debug("调试细节")
    reporter.close

    assert_not_includes stdout.string, "调试细节"
    assert_match(/\[DEBUG\] 调试细节/, File.read(File.join(@tmpdir, "run.log")))
  end

  # --- OutputWriter（落盘与退化保护） ----------------------------------------

  test "空结果不会覆盖已有输出，另存为 degraded 文件" do
    output_dir = File.join(@tmpdir, "output")
    FileUtils.mkdir_p(output_dir)
    path = File.join(output_dir, "#{EventResearch.slug("测试大会")}.json")
    File.write(path, JSON.generate({ "awards" => [ { "rank" => "一等奖" } ] }))

    EventResearch::OutputWriter.write("测试大会", empty_result, reporter: reporter, output_dir: output_dir)

    assert_equal [ { "rank" => "一等奖" } ], JSON.parse(File.read(path))["awards"], "已有结果不该被覆盖"
    assert File.exist?(File.join(output_dir, "#{EventResearch.slug("测试大会")}.degraded.json"))
  end

  test "有奖项的结果正常覆盖输出，且是原子替换" do
    output_dir = File.join(@tmpdir, "output")
    result = { "awards" => [ { "rank" => "一等奖" } ] }

    EventResearch::OutputWriter.write("测试大会", result, reporter: reporter, output_dir: output_dir)

    saved = JSON.parse(File.read(File.join(output_dir, "#{EventResearch.slug("测试大会")}.json")))
    assert_equal result, saved
    assert_empty Dir.glob(File.join(output_dir, "*.tmp"))
  end

  private

  def reporter
    @reporter ||= EventResearch::Reporter.new(->(_level, _message) { })
  end

  def empty_result
    {
      "event" => { "name" => "测试大会", "year" => nil, "edition" => nil },
      "awards" => []
    }
  end
end
