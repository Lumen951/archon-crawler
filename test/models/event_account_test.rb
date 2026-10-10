require "test_helper"

# == Schema Information
#
# Table name: accounts
#
#  id                    :bigint           not null, primary key
#  activity_score        :integer          default(0), not null
#  articles_count        :integer          default(0), not null
#  articles_last_30_days :integer          default(0), not null
#  articles_last_7_days  :integer          default(0), not null
#  crawl_rule            :jsonb            not null
#  fakeid                :string           not null
#  last_crawled_at       :datetime
#  last_published_at     :datetime
#  metadata              :jsonb
#  next_crawl_at         :datetime
#  nickname              :string           not null
#  round_head_img        :string
#  status                :integer          default(0)
#  total_articles        :integer          default(0)
#  twitter_screen_name   :string
#  type                  :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#
# Indexes
#
#  index_accounts_on_fakeid                        (fakeid) UNIQUE
#  index_accounts_on_metadata                      (metadata) USING gin
#  index_accounts_on_status                        (status)
#  index_accounts_on_status_and_last_published_at  (status,last_published_at)
#  index_accounts_on_status_and_next_crawl_at      (status,next_crawl_at)
#  index_accounts_on_twitter_screen_name           (twitter_screen_name)
#  index_accounts_on_type                          (type)
#
class EventAccountTest < ActiveSupport::TestCase
  test "是 Account 的 STI 子类，但不进入抓取管线" do
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:test-1")

    assert account.event?
    assert_equal "EventAccount", account.type
    assert_not EventAccount.crawl_enabled?, "调度器必须跳过活动研究平台"
    assert_equal "活动研究", account.platform_name
  end

  test "event_config 读写只碰 metadata 的 event_config 子对象，其它键保留" do
    account = EventAccount.new(nickname: "测试大会", metadata: { "source" => "manual" })

    account.event_config = { "keywords" => "路演, 决赛", "purpose" => "找创始人" }

    assert_equal "manual", account.metadata["source"]
    assert_equal "找创始人", account.event_config["purpose"]
  end

  test "关键词支持换行与中英文逗号分隔，保存时归一化为去重数组" do
    account = EventAccount.new(
      nickname: "测试大会",
      fakeid: "event:test-2",
      event_config: { keywords: "路演\n决赛，路演 ,半决赛", purpose: "尽调" }
    )

    assert account.save
    assert_equal [ "路演", "决赛", "半决赛" ], account.reload.keywords
  end

  test "url 与目的保存时去除首尾空白，空值归一为 nil" do
    account = EventAccount.new(
      nickname: "测试大会",
      fakeid: "event:test-3",
      event_config: { url: "  https://a.com/official  ", purpose: "  ", keywords: nil }
    )

    assert account.save
    config = account.reload.event_config
    assert_equal "https://a.com/official", config["url"]
    assert_nil config["purpose"]
    assert_equal [], config["keywords"]
  end

  test "指定页面必须是有 http(s) 链接才允许保存" do
    account = EventAccount.new(
      nickname: "测试大会",
      fakeid: "event:test-5",
      event_config: { url: "javascript:alert(1)" }
    )

    assert_not account.valid?
    assert_match(/http\(s\)/, account.errors.full_messages.join("；"))
  end

  test "research_config 与 Researcher 的关键字参数对齐，空值收敛为 nil" do
    account = EventAccount.new(
      nickname: "测试大会",
      event_config: { url: "https://a.com", keywords: [ "路演" ] }
    )

    config = account.research_config

    assert_equal [ "路演" ], config[:keywords]
    assert_equal "https://a.com", config[:seed_url]
    assert_nil config[:purpose]
    assert_nil config[:other_information]
  end

  test "活动级飞书目标支持群聊和私信，并回退到全局配置" do
    account = EventAccount.new(
      nickname: "测试大会",
      event_config: { feishu_receive_id: "ou_user", feishu_receive_id_type: "open_id" }
    )

    assert_equal({ receive_id: "ou_user", receive_id_type: "open_id" }, account.feishu_target)

    account.event_config = { feishu_receive_id: nil, feishu_receive_id_type: nil, feishu_chat_id: "oc_legacy" }
    assert_equal({ receive_id: "oc_legacy", receive_id_type: "chat_id" }, account.feishu_target)

    account.event_config = { feishu_receive_id: nil, feishu_receive_id_type: nil, feishu_chat_id: nil }
    Option.feishu_receive_id = "oc_global"
    Option.feishu_receive_id_type = "chat_id"
    assert_equal({ receive_id: "oc_global", receive_id_type: "chat_id" }, account.feishu_target)
  end

  test "删除账号时级联删除调研记录" do
    account = EventAccount.create!(nickname: "测试大会", fakeid: "event:test-4")
    run = EventResearchRun.create!(account: account, status: :completed)

    account.destroy!

    assert_not EventResearchRun.exists?(run.id)
  end
end
