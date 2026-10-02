#!/usr/bin/env ruby
# frozen_string_literal: true

# 事件调研 CLI：输入一个活动名，跑一轮完整调研，把结果 JSON 写到 output/ 下。
#
# 调研核心流程在 lib/event_research/（与应用内 EventResearchJob 共用同一份代码，
# Rails 启动后按需自动加载），本文件只做 CLI 装配：参数解析、密钥来源、
# 日志落盘（stdout + run.log）、结果写文件。
#
# Usage:
#
#   set -a; source .env; set +a          # SERPER_API_KEY 在仓库根目录的 .env 里（也可用 Option）
#   ./script/event_research.rb "科创中国创新创业投资大会" [--refresh] [--concurrency N]
#
# Output:
#   ./output/<event-slug>.json            # 结果
#   ./tmp/event_research/<slug>/run.log   # 本次运行的完整日志（带时间戳与级别）
#   ./tmp/event_research/<slug>/cache/    # 搜索 / 网页 / LLM 缓存，断点续跑的依托
#
# LLM 调用统一走应用内的 LlmClient（OpenAI 兼容代理），密钥 / 模型 / 代理地址
# 来自 Option（openai_api_key / openai_model / openai_proxy_url），在 /admin/settings 配置，
# 所以脚本需要自己加载 Rails 环境（与 bin/website_crawler_debug.rb 一致）。
#
# SERPER_API_KEY 优先取环境变量，未设置时回落到 Option.serper_api_key；
# 天眼查 Token 来自 Option（tianyancha_api_key），未配置时跳过工商信息补全。
#
# 关于断点续跑：抓取到的网页正文、Serper 结果、LLM 抽取结果都按 key 落盘到
# tmp/event_research/<slug>/cache/，重跑时直接命中，只有没算完的部分会真的重算。
# --refresh 忽略已有缓存重算（仍会写回）。删掉对应目录即可只重置某一类缓存。
#
# 注意：不要改用 `rails runner` 执行 —— runner 下 __FILE__ 与 $PROGRAM_NAME 不同，
# 文件末尾的入口判断不会命中，脚本会静默什么都不做。

require_relative "../config/environment"
require "optparse"

module EventResearch
  OUTPUT_DIR = Rails.root.join("output")
  WORK_DIR = Rails.root.join("tmp", "event_research")

  # CLI 的 Reporter sink：stdout 保持可读的运行输出，同时把带时间戳与级别的行
  # 追加进 run.log；debug 只写日志不刷屏。
  class CliSink
    def initialize(log_path, stdout: $stdout)
      @log_path = log_path.to_s
      @stdout = stdout
      # 输出被重定向到文件时 stdout 是块缓冲的，进度会卡着不出现（run.log 才是权威时间线，
      # 但这行让人能 tail -f 看进度）
      @stdout.sync = true if @stdout.respond_to?(:sync=)
      FileUtils.mkdir_p(File.dirname(@log_path))
      @file = File.open(@log_path, "a")
      @file.sync = true
    end

    attr_reader :log_path

    def call(level, message)
      case level
      when :info then @stdout.puts("#{stamp} #{message}")
      when :warn then @stdout.puts("#{stamp}   ! #{message}")
      when :error then @stdout.puts("#{stamp}   !! #{message}")
      end

      @file.puts("#{Time.current.iso8601} [#{level.to_s.upcase}] #{message}")
    end

    def close
      @file.close
    end

    private

    # stdout 只精确到秒：终端里是给人看进度的，跨天 / 精确定位以 run.log 的
    # iso8601 为准（那里同时还有级别）。
    def stamp
      "[#{Time.current.strftime('%H:%M:%S')}]"
    end
  end

  # 结果写文件（原子替换），并保留「不用一次空结果盖掉之前的好结果」的保护：
  # 退化结果另存 .degraded.json。应用内不走这里 —— 那边每次运行是独立的一行
  # EventResearchRun，退化结果直接标 failed 存库。
  module OutputWriter
    module_function

    def write(event, result, reporter:, output_dir: OUTPUT_DIR)
      path = File.join(output_dir.to_s, "#{EventResearch.slug(event)}.json")

      if EventResearch.degenerate_result?(result) && existing_awards?(path)
        degraded_path = path.sub(/\.json\z/, ".degraded.json")
        write_json(degraded_path, result)
        reporter.warn("本次结果为空，未覆盖已有输出；已另存为 #{degraded_path}")
        return
      end

      write_json(path, result)
      reporter.info("=" * 80)
      reporter.info("Saved: #{path}")
      reporter.info("=" * 80)
    end

    # 先写 tmp 再 rename：中断不会留下半截 JSON
    def write_json(path, result)
      tmp = "#{path}.#{Process.pid}.tmp"

      FileUtils.mkdir_p(File.dirname(path))
      File.write(tmp, JSON.pretty_generate(result, ensure_ascii: false))
      File.rename(tmp, path)
    end

    def existing_awards?(path)
      return false unless File.exist?(path)

      JSON.parse(File.read(path))["awards"].to_a.any?
    rescue JSON::ParserError
      false
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = { refresh: false, concurrency: EventResearch::FETCH_CONCURRENCY }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ./script/event_research.rb \"活动名称\" [--refresh] [--concurrency N]"
    opts.on("--refresh", "忽略已有缓存，全部重新计算（仍会写回缓存）") { options[:refresh] = true }
    opts.on("--concurrency N", Integer, "网页抓取并发数（默认 #{EventResearch::FETCH_CONCURRENCY}）") do |value|
      # 0 会让 Async::Semaphore 永远等不到空位（死锁），提前挡住
      raise OptionParser::InvalidArgument, "并发数必须 >= 1" if value < 1

      options[:concurrency] = value
    end
    opts.on("-h", "--help", "显示帮助") do
      puts opts
      exit 0
    end
  end

  begin
    parser.parse!
  rescue OptionParser::ParseError => e
    warn e.message
    warn parser
    exit 1
  end

  event = ARGV.join(" ").strip

  if event.empty?
    warn <<~USAGE
      Usage:

        set -a; source .env; set +a
        ./script/event_research.rb "科创中国创新创业投资大会" [--refresh] [--concurrency N]

      LLM 密钥 / 模型 / 代理地址来自 Option，在 /admin/settings 配置：
        openai_api_key / openai_model / openai_proxy_url
      SERPER_API_KEY 取环境变量，未设置时回落 Option.serper_api_key。
      天眼查 Token 在 /admin/settings 配置（tianyancha_api_key），
      未配置时跳过工商信息补全。
    USAGE

    exit 1
  end

  unless LlmClient.configured?
    warn "未配置 OpenAI API 密钥（openai_api_key），请先在 /admin/settings 配置"
    exit 1
  end

  reporter = nil
  cache = nil

  begin
    work_dir = EventResearch::WORK_DIR.join(EventResearch.slug(event))
    reporter = EventResearch::Reporter.new(EventResearch::CliSink.new(work_dir.join("run.log")))
    cache = EventResearch::RunCache.new(root: work_dir, reporter: reporter, refresh: options[:refresh])

    reporter.info("Run log: #{work_dir.join('run.log')}")
    reporter.info("抓取并发数: #{options[:concurrency]}")
    reporter.info("Cache: #{cache.root}#{options[:refresh] ? "（--refresh：本次忽略已有缓存）" : ""}")

    result = EventResearch::Researcher.new(
      event: event,
      search: EventResearch::SerperSearch.new(
        api_key: ENV["SERPER_API_KEY"].presence || Option.serper_api_key, cache: cache, reporter: reporter
      ),
      pages: EventResearch::PageFetcher.new(cache: cache, reporter: reporter, concurrency: options[:concurrency]),
      llm: LlmClient.new,
      tianyancha: EventResearch::TianyanchaClient.new(
        api_key: Option.tianyancha_api_key, cache: cache, reporter: reporter
      ),
      cache: cache,
      reporter: reporter
    ).run

    EventResearch::OutputWriter.write(event, result, reporter: reporter)
    reporter.info("缓存统计: #{cache.summary}")
  rescue Interrupt
    # Ctrl-C：已完成的部分都在缓存里，直接重跑即可续上
    reporter&.warn("已中断（Ctrl-C）。缓存已保留，重跑同一条命令会从断点继续。")
    reporter&.info("缓存统计: #{cache&.summary}")
    exit 130
  rescue EventResearch::SerperSearch::ApiKeyError => e
    reporter ? reporter.error(e.message, exception: e) : warn(e.message)
    exit 1
  rescue StandardError => e
    reporter ? reporter.error("运行失败: #{e.message}", exception: e) : warn("#{e.class}: #{e.message}")
    exit 1
  ensure
    reporter&.close
  end
end
