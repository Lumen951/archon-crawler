require "test_helper"

class EventResearchWeeklyDigestTextTest < ActiveSupport::TestCase
  test "渲染活动研究报告：重点人脉、项目、奖项、联系方式、证据和详情链接" do
    digest = EventWeeklyDigest.create!(
      week_start: Date.new(2026, 10, 5),
      sections: sections
    )

    text = EventResearch::WeeklyDigestText.call(digest)

    assert_match "活动研究报告（2026-10-05）", text
    assert_match "覆盖 1 个活动 · 重点人脉 1 位 · 项目 1 个 · 奖项/入选 1 条 · 联系方式 1 条", text
    assert_match "重点人脉", text
    assert_match "1. 张三｜创始人｜甲公司", text
    assert_match "项目：E2E项目", text
    assert_match "奖项/事件：Demo Day 优胜奖", text
    assert_match "联系方式：邮箱 zhangsan@x.dev", text
    assert_match "新增项目", text
    assert_match "E2E项目｜甲公司", text
    assert_match "奖项/入选/路演", text
    assert_match "Demo Day 优胜奖", text
    assert_match "可跟进联系方式", text
    assert_match "证据：张三创办甲公司", text
    assert_match "https://example.com/event", text
    assert_match "▍测试大会：新增人脉 1，项目 1，联系方式 1（run#7）", text
    assert text.end_with?("查看研究报告详情：#{digest_url(digest)}")
  end

  test "无动态的活动给占位说明，不整段消失" do
    digest = EventWeeklyDigest.create!(
      week_start: Date.new(2026, 10, 5),
      sections: { "summary" => { "events" => 1, "people" => 0, "projects" => 0, "awards" => 0, "contacts" => 0 },
                  "highlights" => {},
                  "events" => [ { "account_id" => 1, "nickname" => "安静的活动", "note" => "本次调研仍在进行中" } ] }
    )

    text = EventResearch::WeeklyDigestText.call(digest)

    assert_match "本次暂未提取到新的创业人脉情报", text
    assert_match "▍安静的活动：本次调研仍在进行中", text
  end

  test "正文超长时截断但保留详情链接" do
    digest = EventWeeklyDigest.create!(
      week_start: Date.new(2026, 10, 5),
      sections: sections(description: "张三" * 5000)
    )

    text = EventResearch::WeeklyDigestText.call(digest)

    assert_operator text.length, :<=, EventResearch::WeeklyDigestText::MAX_CHARS
    assert text.end_with?("查看研究报告详情：#{digest_url(digest)}")
  end

  private

  def sections(description: "张三创办甲公司")
    person = {
      "name" => "张三",
      "role_or_title" => "创始人",
      "company" => "甲公司",
      "project" => "E2E项目",
      "description" => description,
      "awards" => [ "Demo Day 优胜奖" ],
      "contact_methods" => [ { "type" => "email", "value" => "zhangsan@x.dev", "evidence" => evidence } ],
      "evidence" => evidence,
      "event_nickname" => "测试大会"
    }
    {
      "week_start" => "2026-10-05",
      "summary" => { "events" => 1, "people" => 1, "companies" => 1, "projects" => 1, "awards" => 1, "contacts" => 1 },
      "highlights" => {
        "people" => [ person ],
        "projects" => [ { "name" => "E2E项目", "company" => "甲公司", "description" => "AI 创业项目", "stage_or_context" => "Demo Day", "evidence" => evidence } ],
        "companies" => [ { "name" => "甲公司", "description" => "企业服务创业公司", "project" => "E2E项目", "evidence" => evidence } ],
        "awards" => [ { "name" => "Demo Day 优胜奖", "recipient_person" => "张三", "event_name" => "测试大会", "evidence" => evidence } ],
        "contacts" => [ { "type" => "email", "value" => "zhangsan@x.dev", "belongs_to" => "张三", "context" => "官网公开邮箱", "evidence" => evidence } ]
      },
      "events" => [
        { "account_id" => 1, "nickname" => "测试大会", "run_id" => 7,
          "completed_at" => "2026-10-08T10:00:00+08:00",
          "totals" => { "awards" => 1, "people" => 1, "companies" => 1, "projects" => 1, "contacts" => 1 },
          "new_people_total" => 1, "projects_total" => 1, "companies_total" => 1, "awards_total" => 1, "contacts_total" => 1,
          "new_people" => [ person ], "projects" => [], "companies" => [], "awards" => [], "contacts" => [], "updates" => [] }
      ]
    }
  end

  def evidence
    [ { "quote" => "张三创办甲公司", "source_url" => "https://example.com/event", "source_title" => "活动公告" } ]
  end

  def digest_url(digest)
    Rails.application.routes.url_helpers.event_weekly_digest_url(
      digest, host: "localhost", port: 3000, protocol: "http"
    )
  end
end
