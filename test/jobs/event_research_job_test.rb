require "test_helper"
require "tmpdir"

# EventResearchJob 的离线测试：Researcher 整体打桩（stub_class_method 替换 .new），
# 只验证编排与状态落库 —— 调研流程本身的测试在 test/lib/event_research_test.rb。
class EventResearchJobTest < ActiveSupport::TestCase
  setup do
    @account = EventAccount.create!(
      nickname: "测试大会",
      fakeid: "event:job-test",
      event_config: { keywords: "路演", purpose: "找创始人", url: "https://a.com/official" }
    )
    @run = EventResearchRun.create!(account: @account, status: :pending)
    Option.serper_api_key = "test-key"
  end

  teardown do
    Option.delete("serper_api_key")
    FileUtils.rm_rf(Rails.root.join("tmp", "event_research"))
  end

  test "成功路径：结果 JSON 存进 run，计数与状态正确" do
    result = successful_result
    with_preflight_ok do
      with_researcher_returning(result) do
        EventResearchJob.perform_now(@run.id)
      end
    end

    @run.reload
    assert_equal "completed", @run.status
    assert_equal result, @run.result
    assert_equal 1, @run.award_count
    assert_equal 1, @run.people_count
    assert_equal 2, @run.company_count
    assert_nil @run.error_message
    assert @run.started_at.present? && @run.completed_at.present?
  end

  test "调研异常时 run 标记失败，错误信息可查" do
    with_preflight_ok do
      with_researcher_raising(StandardError.new("Serper 请求失败: Net::ReadTimeout")) do
        EventResearchJob.perform_now(@run.id)
      end
    end

    @run.reload
    assert_equal "failed", @run.status
    assert_match(/Serper 请求失败/, @run.error_message)
    assert @run.completed_at.present?
  end

  test "退化结果保留数据但标 failed" do
    with_preflight_ok do
      with_researcher_returning({ "event" => { "name" => "测试大会" }, "awards" => [], "metadata" => {} }) do
        EventResearchJob.perform_now(@run.id)
      end
    end

    @run.reload
    assert_equal "failed", @run.status
    assert_match(/没有提取到有效数据/, @run.error_message)
    assert @run.result.is_a?(Hash), "退化结果也要留档供检查"
  end

  test "前置检查：未配置 LLM 密钥时 fail-fast，不进调研流程" do
    stub_class_method(LlmClient, :configured?, -> { false }) do
      researcher_called = false
      with_researcher_stub(->(**_kwargs) { researcher_called = true; Object.new }) do
        EventResearchJob.perform_now(@run.id)
      end
      assert_not researcher_called, "缺密钥时不应执行调研"
    end

    @run.reload
    assert_equal "failed", @run.status
    assert_match(/openai_api_key/, @run.error_message)
  end

  test "前置检查：未配置 Serper 密钥时 fail-fast" do
    Option.delete("serper_api_key")
    with_env("SERPER_API_KEY" => nil) do
      stub_class_method(LlmClient, :configured?, -> { true }) do
        EventResearchJob.perform_now(@run.id)
      end
    end

    @run.reload
    assert_equal "failed", @run.status
    assert_match(/serper_api_key/, @run.error_message)
  end

  test "重复投递安全：第二次 perform 不再执行调研" do
    calls = 0
    fake = fake_researcher(successful_result)
    with_preflight_ok do
      with_researcher_stub(->(**_kwargs) { calls += 1; fake }) do
        EventResearchJob.perform_now(@run.id)
        EventResearchJob.perform_now(@run.id)
      end
    end

    assert_equal 1, calls, "已完成 / 已在运行的 run 不应被二次执行"
  end

  test "run 记录不存在时不抛异常（job 迟到投递）" do
    assert_nothing_raised { EventResearchJob.perform_now(999_999_999) }
  end

  test "账号配置注入调研：事件名 / 关键词 / 目的 / 种子页面" do
    captured = nil
    fake = fake_researcher(successful_result)
    with_preflight_ok do
      with_researcher_stub(lambda { |**kwargs|
        captured = kwargs
        fake
      }) do
        EventResearchJob.perform_now(@run.id)
      end
    end

    assert_equal "测试大会", captured[:event]
    assert_equal [ "路演" ], captured[:keywords]
    assert_equal "找创始人", captured[:purpose]
    assert_equal "https://a.com/official", captured[:seed_url]
    assert_equal successful_result, @run.reload.result
  end

  private

  def successful_result
    {
      "event" => { "name" => "测试大会", "year" => 2025, "edition" => nil },
      "awards" => [ { "rank" => "一等奖", "people" => [ { "name" => "张三" } ] } ],
      "companies" => [ { "name" => "甲公司", "found" => true }, { "name" => "乙公司", "found" => true } ],
      "metadata" => { "people_found" => 1 }
    }
  end

  def fake_researcher(result)
    fake_object({ run: -> { result } })
  end

  # 只实现指定方法的替身（项目没有 mocha）
  def fake_object(methods)
    object = Object.new
    methods.each do |name, body|
      object.define_singleton_method(name) { |*args, **kwargs, &block| body.call(*args, **kwargs, &block) }
    end
    object
  end

  def with_researcher_returning(result, &block)
    # define_method 会把 lambda 的 self 换成接收者（Researcher 类），
    # fake 对象必须先在测试实例上构建好、以局部变量传入
    fake = fake_researcher(result)
    with_researcher_stub(->(**_kwargs) { fake }, &block)
  end

  def with_researcher_raising(error, &block)
    fake = fake_object({ run: -> { raise error } })
    with_researcher_stub(->(**_kwargs) { fake }, &block)
  end

  def with_researcher_stub(constructor, &block)
    stub_class_method(EventResearch::Researcher, :new, constructor, &block)
  end

  # 测试环境没有配置 LLM 密钥，先绕过前置检查（ Serper key 在 setup 里已写入 Option）
  def with_preflight_ok(&block)
    stub_class_method(LlmClient, :configured?, -> { true }, &block)
  end

  def with_env(env)
    old = {}
    env.each { |key, value| old[key] = ENV[key]; env[key].nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
