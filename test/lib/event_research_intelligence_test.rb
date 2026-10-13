require "test_helper"

class EventResearchIntelligenceTest < ActiveSupport::TestCase
  test "normalize guarantees intelligence arrays" do
    intelligence = EventResearch::Intelligence.normalize({})

    assert_equal %w[people companies projects awards contacts], intelligence.keys
    assert_equal [], intelligence["people"]
    assert_equal [], intelligence["contacts"]
  end

  test "normalizes explicit intelligence and keeps evidence backed contacts" do
    intelligence = EventResearch::Intelligence.normalize(
      "intelligence" => {
        "people" => [
          { "name" => " 张三 ", "role" => "创始人", "organization" => "甲公司",
            "contacts" => [ { "type" => "Email", "value" => "zs@example.com", "evidence" => [ { "quote" => "邮箱 zs@example.com", "source_url" => "https://example.com/a" } ] } ],
            "evidence" => [ { "field" => "name", "quote" => "张三创办甲公司", "source_url" => "https://example.com/a" } ],
            "confidence" => "high" }
        ],
        "contacts" => [ { "type" => "wechat", "value" => "mp-demo", "belongs_to" => "张三" } ]
      }
    )

    person = intelligence["people"].sole
    assert_equal "张三", person["name"]
    assert_equal "创始人", person["role_or_title"]
    assert_equal "甲公司", person["company"]
    assert_equal "email", person["contact_methods"].sole["type"]
    assert_equal "邮箱 zs@example.com", EventResearch::Intelligence.contact_label(person["contact_methods"].sole)
    assert_match "张三创办甲公司", EventResearch::Intelligence.evidence_label(person)
    assert_equal "wechat", intelligence["contacts"].sole["type"]
  end

  test "legacy awards shape maps to people projects awards contacts" do
    intelligence = EventResearch::Intelligence.normalize(
      "event" => { "name" => "测试大会" },
      "awards" => [
        { "rank" => "一等奖", "award" => "创新奖", "category" => "初创组",
          "evidence" => [ { "quote" => "E2E项目获得一等奖", "source_url" => "https://example.com/event" } ],
          "project" => { "name" => "E2E项目", "organization" => "甲公司", "description" => "AI 创业项目" },
          "people" => [ { "name" => "李四", "role" => "CEO",
                          "contact" => { "email" => "lisi@example.com" },
                          "employment" => [ { "organization" => "甲公司" } ] } ] }
      ],
      "companies" => []
    )

    assert_equal "李四", intelligence["people"].sole["name"]
    assert_equal "E2E项目", intelligence["projects"].sole["name"]
    assert_equal "初创组 · 一等奖", intelligence["awards"].sole["name"]
    assert_equal "lisi@example.com", intelligence["contacts"].sole["value"]
    assert_match "E2E项目获得一等奖", EventResearch::Intelligence.evidence_label(intelligence["people"].sole)
  end
end
