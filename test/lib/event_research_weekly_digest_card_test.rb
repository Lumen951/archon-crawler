require "test_helper"

class EventResearchWeeklyDigestCardTest < ActiveSupport::TestCase
  test "渲染带 header、加粗摘要与详情按钮的卡片" do
    digest = EventWeeklyDigest.create!(week_start: Date.new(2026, 10, 5), sections: sections)

    card = EventResearch::WeeklyDigestCard.call(digest, receive_id: "oc_test")

    assert_equal "blue", card.dig(:header, :template)
    assert_match "活动研究报告", card.dig(:header, :title, :content)
    assert_match "**1**", card.dig(:elements, 0, :text, :content)
    assert_match "**重点人脉**", card.dig(:elements, 1, :text, :content)
    assert_equal "查看研究报告详情", card.dig(:elements, -1, :actions, 0, :text, :content)
  end

  test "清理动态 Markdown 和提及标签" do
    digest = EventWeeklyDigest.create!(week_start: Date.new(2026, 10, 5), sections: sections(name: "<at user_id=all>**张三**</at>"))

    text = EventResearch::WeeklyDigestCard.call(digest).dig(:elements, 1, :text, :content)

    assert_no_match "<at", text
    assert_no_match "**张三**", text
  end

  test "超长内容保留详情按钮且请求体在预算内" do
    data = sections
    person = data.dig("highlights", "people").first
    person["description"] = ('中文引号"与反斜杠\\' * 1000)
    person["awards"] = Array.new(30) { "奖项" * 500 }
    data["highlights"]["people"] = Array.new(20) { person.deep_dup }
    digest = EventWeeklyDigest.create!(week_start: Date.new(2026, 10, 5), sections: data)

    card = EventResearch::WeeklyDigestCard.call(digest, receive_id: "oc_test")
    request = { receive_id: "oc_test", msg_type: "interactive", content: card.to_json }.to_json

    assert_operator request.bytesize, :<=, EventResearch::WeeklyDigestCard::MAX_REQUEST_BYTES
    assert_equal "查看研究报告详情", card.dig(:elements, -1, :actions, 0, :text, :content)
  end

  private

  def sections(name: "张三")
    person = { "name" => name, "role_or_title" => "创始人", "company" => "甲公司", "project" => "项目",
               "description" => "公开邮箱", "contact_methods" => [ { "type" => "email", "value" => "zs@x.dev" } ] }
    {
      "summary" => { "events" => 1, "people" => 1, "projects" => 1, "awards" => 1, "contacts" => 1 },
      "api_usage" => { "search" => { "api_calls" => 2, "cache_hits" => 3 }, "tianyancha" => { "api_calls" => 4, "cache_hits" => 5 } },
      "highlights" => { "people" => [ person ], "projects" => [], "companies" => [], "awards" => [], "contacts" => [] },
      "events" => [ { "nickname" => "测试大会", "new_people_total" => 1, "projects_total" => 1, "contacts_total" => 1 } ]
    }
  end
end
