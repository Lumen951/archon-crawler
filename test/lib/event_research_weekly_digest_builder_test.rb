require "test_helper"

class EventResearchWeeklyDigestBuilderTest < ActiveSupport::TestCase
  setup do
    @account = EventAccount.create!(nickname: "测试大会", fakeid: "event:digest-builder", event_config: { weekly_research_enabled: true })
    @week_start = Date.current.beginning_of_week
  end

  test "用 intelligence 生成摘要、重点人脉、项目、奖项、联系方式" do
    run = EventResearchRun.create!(account: @account, status: :completed,
      completed_at: Time.current, people_count: 1, result: intelligence_result)

    sections = build_sections
    event = sections["events"].sole

    assert_equal run.id, event["run_id"]
    assert_equal({ "events" => 1, "people" => 1, "companies" => 1, "projects" => 1, "awards" => 1, "contacts" => 1 }, sections["summary"])
    assert_equal "张三", sections.dig("highlights", "people").sole["name"]
    assert_equal "E2E项目", sections.dig("highlights", "projects").sole["name"]
    assert_equal "甲公司", sections.dig("highlights", "companies").sole["name"]
    assert_equal "Demo Day 优胜奖", sections.dig("highlights", "awards").sole["name"]
    assert_equal "zhangsan@x.dev", sections.dig("highlights", "contacts").sole["value"]
    assert_match "张三创办甲公司", EventResearch::Intelligence.evidence_label(sections.dig("highlights", "people").sole)
    assert_equal 1, event.dig("totals", "contacts")
  end

  test "基线已有人物不算新增，新补齐的联系方式进信息补充" do
    EventResearchRun.create!(account: @account, status: :completed,
      completed_at: @week_start.beginning_of_day - 1.hour,
      result: intelligence_result(contact: nil))
    EventResearchRun.create!(account: @account, status: :completed,
      completed_at: Time.current, result: intelligence_result)

    event = build_sections["events"].sole

    assert_empty event["new_people"]
    assert_equal [ "张三｜新增 联系方式" ], event["updates"]
    assert_equal 1, event["contacts_total"]
  end

  test "有联系方式的新人物排在前面" do
    EventResearchRun.create!(account: @account, status: :completed,
      completed_at: Time.current,
      result: {
        "event" => { "name" => "测试大会" },
        "awards" => [],
        "companies" => [],
        "intelligence" => {
          "people" => [
            person_intelligence("无联系方式", contact: nil),
            person_intelligence("有邮箱", contact: "a@x.dev")
          ]
        }
      })

    people = build_sections.dig("events", 0, "new_people")

    assert_equal "有邮箱", people.first["name"]
    assert_equal "无联系方式", people.second["name"]
  end

  test "legacy awards shape still produces best effort intelligence" do
    EventResearchRun.create!(account: @account, status: :completed,
      completed_at: Time.current, people_count: 1,
      result: legacy_result([ award("一等奖", [ legacy_person("李四", email: "lisi@x.dev") ]) ]))

    sections = build_sections
    event = sections["events"].sole

    assert_equal 1, event["new_people_total"]
    assert_equal "李四", event["new_people"].sole["name"]
    assert_equal "E2E新项目", event["projects"].sole["name"]
    assert_equal "lisi@x.dev", event["contacts"].sole["value"]
  end

  test "任务快照内的失败和未完成活动都保留占位说明" do
    EventResearchRun.create!(account: @account, status: :failed,
      created_at: Time.current, error_message: "LLM 超时")

    idle = EventAccount.create!(nickname: "没调研的活动", fakeid: "event:digest-idle", event_config: { weekly_research_enabled: true })

    sections = build_sections([ @account, idle ])

    assert_equal [ @account.id, idle.id ].sort, sections["events"].map { |event| event["account_id"] }.sort
    failed_event = sections["events"].find { |event| event["account_id"] == @account.id }
    idle_event = sections["events"].find { |event| event["account_id"] == idle.id }
    assert_includes failed_event["note"], "本次调研失败"
    assert_includes failed_event["note"], "LLM 超时"
    assert_includes idle_event["note"], "本次调研未完成"
  end

  private

  def build_sections(accounts = [ @account ])
    task = EventResearchTask.create_for!(accounts, source: :manual_selected)
    task.event_research_task_accounts.each do |item|
      run = item.account.event_research_runs.order(created_at: :desc).first
      item.update!(
        event_research_run: run,
        status: run ? (run.completed? ? :completed : :failed) : :pending,
        error_message: run&.error_message
      )
    end
    EventResearch::WeeklyDigestBuilder.call(task)
  end

  def intelligence_result(contact: "zhangsan@x.dev")
    contacts = contact ? [ { "type" => "email", "value" => contact, "belongs_to" => "张三", "context" => "官网公开邮箱", "evidence" => evidence } ] : []
    {
      "event" => { "name" => "测试大会" },
      "awards" => [],
      "companies" => [],
      "intelligence" => {
        "people" => [ person_intelligence("张三", contact: contact) ],
        "projects" => [ { "name" => "E2E项目", "company" => "甲公司", "description" => "AI 创业项目", "stage_or_context" => "Demo Day", "people" => [ "张三" ], "awards" => [ "Demo Day 优胜奖" ], "evidence" => evidence, "confidence" => "high" } ],
        "companies" => [ { "name" => "甲公司", "description" => "企业服务创业公司", "project" => "E2E项目", "people" => [ "张三" ], "evidence" => evidence, "confidence" => "high" } ],
        "awards" => [ { "name" => "Demo Day 优胜奖", "recipient_person" => "张三", "recipient_company_or_project" => "E2E项目", "event_name" => "测试大会", "evidence" => evidence, "confidence" => "high" } ],
        "contacts" => contacts
      }
    }
  end

  def person_intelligence(name, contact: "zhangsan@x.dev")
    {
      "name" => name,
      "role_or_title" => "创始人",
      "company" => "甲公司",
      "project" => "E2E项目",
      "description" => "张三创办甲公司",
      "awards" => [ "Demo Day 优胜奖" ],
      "contact_methods" => (contact ? [ { "type" => "email", "value" => contact, "evidence" => evidence } ] : []),
      "evidence" => evidence,
      "confidence" => "high"
    }
  end

  def evidence
    [ { "quote" => "张三创办甲公司并公开邮箱", "source_url" => "https://example.com/event", "source_title" => "活动公告" } ]
  end

  def award(rank, people, project: "E2E新项目")
    { "rank" => rank, "award" => "创新奖", "category" => "初创组",
      "project" => { "name" => project, "organization" => "项目单位" }, "people" => people }
  end

  def legacy_person(name, role: "CTO", email: nil, phone: nil, org: "乙科技有限公司")
    { "name" => name, "role" => role,
      "contact" => { "email" => email, "phone" => phone, "website" => nil },
      "employment" => [ { "organization" => org, "title" => role, "start_year" => "2020", "end_year" => nil } ] }
  end

  def legacy_result(awards)
    { "event" => { "name" => "测试大会" }, "awards" => awards, "companies" => [] }
  end
end
