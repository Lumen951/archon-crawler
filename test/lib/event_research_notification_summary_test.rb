require "test_helper"

class EventResearchNotificationSummaryTest < ActiveSupport::TestCase
  setup do
    @account = EventAccount.create!(nickname: "科创中国创新创业投资大会", fakeid: "event:summary-test")
    @run = EventResearchRun.create!(account: @account, status: :completed, completed_at: Time.zone.parse("2026-10-02 16:06"), result: {})
  end

  test "首轮通知归并重复奖项并保留项目上下文" do
    @run.update!(result: {
      "awards" => [
        award("企业组一等奖", "一等奖", "企业组", project_name: "智能诊断平台", organization: "甲公司", industry: "医疗健康"),
        award("企业组一等奖", "一等奖", "企业组", project_name: "智能诊断平台", organization: "甲公司", industry: "医疗健康"),
        award("团队组二等奖", "二等奖", "团队组")
      ]
    })

    text = EventResearch::NotificationSummary.initial(@account, @run)

    assert_match "奖项/项目（3 条，去重后 2 条）", text
    assert_equal 1, text.scan("企业组 · 一等奖｜智能诊断平台 · 甲公司 · 医疗健康").length
    assert_match "团队组 · 二等奖", text
    assert_match research_url, text
  end

  test "公司通知只包含紧凑公开摘要且限制展示数量" do
    companies = 11.times.map do |index|
      {
        "name" => "公司#{index}",
        "industry" => "软件和信息技术服务业",
        "status" => "存续",
        "established_at" => "2024-01-#{format('%02d', index + 1)}",
        "website" => "https://company#{index}.example.com",
        "tags" => [ "人工智能", "企业服务" ],
        "query" => "公司#{index}",
        "found" => true,
        "phone" => "13800000000",
        "emails" => [ "private@example.com" ],
        "credit_code" => "SECRET-CREDIT-CODE",
        "legal_person" => "某法人",
        "reg_location" => "详细注册地址",
        "registered_capital" => "1000万人民币",
        "business_scope" => "不应出现在通知中的超长经营范围",
        "key_people" => [ { "name" => "某高管" } ],
        "source" => { "url" => "https://source.example.com" }
      }
    end
    @run.update!(result: { "companies" => companies + [ companies.first.dup ] })

    text = EventResearch::NotificationSummary.initial(@account, @run)

    assert_match "公司（12 条，去重后 11 条）", text
    assert_match "- 公司0｜软件和信息技术服务业；存续；成立 2024-01-01；官网 https://company0.example.com；标签 人工智能、企业服务", text
    assert_match "- 另有 1 条未展示", text
    refute_match "SECRET-CREDIT-CODE", text
    refute_match "13800000000", text
    refute_match "private@example.com", text
    refute_match "详细注册地址", text
    refute_match "不应出现在通知中的超长经营范围", text
    refute_match "query:", text
  end

  test "周报以人物上下文和可展示新增字段描述变化" do
    diff = {
      "awards" => [],
      "companies" => [],
      "people" => [
        { "name" => "张三", "role" => "创始人", "_award" => "企业组一等奖", "contact" => { "phone" => "13800000000" } }
      ],
      "updates" => [
        {
          "key" => "company|甲公司",
          "before" => { "name" => "甲公司", "industry" => nil, "business_scope" => nil },
          "after" => { "name" => "甲公司", "industry" => "人工智能", "business_scope" => "超长经营范围" }
        },
        {
          "key" => "award|一等奖",
          "before" => { "rank" => "一等奖", "project" => { "name" => nil } },
          "after" => { "rank" => "一等奖", "project" => { "name" => "智能诊断平台" } }
        },
        {
          "key" => "company|无可展示变化",
          "before" => { "name" => "无可展示变化", "business_scope" => nil },
          "after" => { "name" => "无可展示变化", "business_scope" => "超长经营范围" }
        }
      ],
      "empty" => false
    }

    text = EventResearch::NotificationSummary.weekly(@account, @run, diff)

    assert_match "新增人物（1）", text
    assert_match "张三｜创始人；关联 企业组一等奖", text
    refute_match "13800000000", text
    assert_match "已有信息补充（3 条，去重后 2 条）", text
    assert_match "甲公司｜新增 行业", text
    assert_match "一等奖｜新增 项目名称", text
    refute_match "超长经营范围", text
    refute_match "无可展示变化", text
    assert_match research_url, text
  end

  test "异常条目安全降级且正文遵守最大长度" do
    @run.update!(result: {
      "awards" => [ nil, "历史奖项" ],
      "companies" => Array.new(200) { |index| { "name" => "公司#{index}", "industry" => "A" * 500 } }
    })

    text = EventResearch::NotificationSummary.initial(@account, @run)

    assert_match "历史奖项", text
    assert_match research_url, text
    assert text.end_with?(research_url)
    assert_operator text.length, :<=, EventResearch::NotificationSummary::MAX_CHARS
  end

  private

  def research_url
    Rails.application.routes.url_helpers.event_account_url(
      @account,
      run_id: @run.id,
      host: "localhost",
      port: 3000,
      protocol: "http"
    )
  end

  def award(rank, award_name, category, project_name: nil, organization: nil, industry: nil)
    {
      "rank" => rank,
      "award" => award_name,
      "category" => category,
      "project" => {
        "name" => project_name,
        "organization" => organization,
        "industry" => industry
      }
    }
  end
end
