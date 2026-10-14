require "test_helper"

class EventWeeklyDigestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Option.delete_all
    @admin = User.create!(
      email_address: "digest-admin@example.com",
      password: "password123",
      password_confirmation: "password123",
      role: :admin,
      email_confirmed_at: Time.current
    )
    post session_path, params: { email_address: @admin.email_address, password: "password123" }
  end

  test "index lists task reports with intelligence counts" do
    digest = EventWeeklyDigest.create!(week_start: Date.current.beginning_of_week, status: :sent, sent_at: Time.current,
      sections: { "summary" => { "events" => 1, "people" => 1, "projects" => 2, "contacts" => 3 },
                  "events" => [ { "nickname" => "测试大会", "new_people" => [ { "name" => "张三" } ], "new_people_total" => 1 } ] })

    get event_weekly_digests_path

    assert_response :success
    assert_match "活动研究报告", response.body
    assert_match digest.period_label, response.body
    assert_match "重点人脉", response.body
  end

  test "show renders highlights evidence contacts per-event detail and payload" do
    digest = EventWeeklyDigest.create!(week_start: Date.current.beginning_of_week, status: :sent,
      payload_text: "📋 活动研究报告\n张三｜创始人",
      sections: sections)

    get event_weekly_digest_path(digest)

    assert_response :success
    assert_match "活动研究报告", response.body
    assert_match "重点人脉", response.body
    assert_match "测试大会", response.body
    assert_match "张三", response.body
    assert_match "zs@x.dev", response.body
    assert_match "获 Demo Day 优胜奖", response.body
    assert_match "https://example.com/event", response.body
    assert_match "当前报告纯文本预览", response.body
    assert_match "重新生成内容", response.body
    assert_match "最近一次推送状态", response.body
  end

  test "resend enqueues delivery with saved payload" do
    digest = EventWeeklyDigest.create!(week_start: Date.current.beginning_of_week, status: :sent, payload_text: "正文")

    assert_enqueued_with(job: EventWeeklyDigestResendJob, args: [ digest.id ]) do
      post resend_event_weekly_digest_path(digest)
    end

    assert_redirected_to event_weekly_digest_path(digest)
  end

  test "重新生成更新内容但不改变投递记录" do
    account = EventAccount.create!(nickname: "重新生成活动", fakeid: "event:regenerate")
    task = EventResearchTask.create_for!([ account ], source: :manual_single)
    run = EventResearchRun.create!(account: account, status: :completed, completed_at: Time.current, result: { "event" => { "name" => "重新生成活动" }, "awards" => [], "companies" => [], "intelligence" => { "people" => [], "projects" => [], "companies" => [], "awards" => [], "contacts" => [] } })
    task.event_research_task_accounts.sole.update!(event_research_run: run, status: :completed)
    task.update!(status: :completed, progress: 1, completed_at: Time.current)
    sent_at = 1.hour.ago
    digest = EventWeeklyDigest.create!(event_research_task: task, week_start: Date.current.beginning_of_week, status: :sent, sent_at: sent_at, error_message: nil, payload_text: "旧正文", sections: {})

    assert_no_enqueued_jobs do
      post regenerate_event_weekly_digest_path(digest)
    end

    assert_redirected_to event_weekly_digest_path(digest)
    digest.reload
    assert digest.sent?
    assert_equal sent_at.to_i, digest.sent_at.to_i
    assert_match "活动研究报告", digest.payload_text
    assert_equal digest.id, EventWeeklyDigest.find_by!(event_research_task: task).id
  end

  test "重新生成需要管理员" do
    delete session_path
    user = User.create!(email_address: "digest-regenerate-member@example.com", password: "password123", password_confirmation: "password123", role: :user, email_confirmed_at: Time.current)
    post session_path, params: { email_address: user.email_address, password: "password123" }
    digest = EventWeeklyDigest.create!(week_start: Date.current.beginning_of_week, payload_text: "正文")

    post regenerate_event_weekly_digest_path(digest)

    assert_redirected_to root_path
  end

  test "resend requires admin" do
    delete session_path
    user = User.create!(
      email_address: "digest-member@example.com",
      password: "password123",
      password_confirmation: "password123",
      role: :user,
      email_confirmed_at: Time.current
    )
    post session_path, params: { email_address: user.email_address, password: "password123" }

    digest = EventWeeklyDigest.create!(week_start: Date.current.beginning_of_week, payload_text: "正文")
    post resend_event_weekly_digest_path(digest)
    assert_redirected_to root_path
  end

  private

  def sections
    evidence = [ { "quote" => "获 Demo Day 优胜奖", "source_url" => "https://example.com/event", "source_title" => "活动公告" } ]
    person = { "name" => "张三", "role_or_title" => "创始人", "company" => "甲公司", "project" => "E2E项目",
               "description" => "获 Demo Day 优胜奖", "awards" => [ "Demo Day 优胜奖" ],
               "contact_methods" => [ { "type" => "email", "value" => "zs@x.dev", "evidence" => evidence } ],
               "evidence" => evidence, "event_nickname" => "测试大会" }
    {
      "summary" => { "events" => 1, "people" => 1, "companies" => 1, "projects" => 1, "awards" => 1, "contacts" => 1 },
      "highlights" => {
        "people" => [ person ],
        "projects" => [ { "name" => "E2E项目", "company" => "甲公司", "evidence" => evidence } ],
        "companies" => [ { "name" => "甲公司", "project" => "E2E项目", "evidence" => evidence } ],
        "awards" => [ { "name" => "Demo Day 优胜奖", "recipient_person" => "张三", "evidence" => evidence } ],
        "contacts" => [ { "type" => "email", "value" => "zs@x.dev", "belongs_to" => "张三", "evidence" => evidence } ]
      },
      "events" => [ { "account_id" => nil, "nickname" => "测试大会", "run_id" => 7,
                      "completed_at" => "2026-10-08T10:00:00+08:00",
                      "totals" => { "awards" => 1, "people" => 1, "companies" => 1, "projects" => 1, "contacts" => 1 },
                      "new_people" => [ person ], "new_people_total" => 1,
                      "projects" => [], "projects_total" => 1,
                      "companies" => [], "companies_total" => 1,
                      "awards" => [], "awards_total" => 1,
                      "contacts" => [], "contacts_total" => 1,
                      "updates" => [] } ]
    }
  end
end
