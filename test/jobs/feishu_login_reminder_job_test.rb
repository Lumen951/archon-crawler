require "test_helper"

class FeishuLoginReminderJobTest < ActiveSupport::TestCase
  setup do
    Option.delete_all
    @sent = []
  end

  # 记录飞书侧的调用，避免真的发请求
  def stub_feishu(enabled: true, &block)
    sent = @sent
    stub_class_methods(
      FeishuNotifier,
      enabled?: -> { enabled },
      send_qr_login: proc { |**kwargs| sent << [ :qr, kwargs[:text] ] },
      send_card: proc { |card, **| sent << [ :card, card ] },
      send_text: proc { |text, **| sent << [ :text, text ] },
      &block
    )
  end

  # provider 打桩：不需要提醒 / 需要提醒
  def stub_provider(needed:, &block)
    stub_class_method(QrLogin::Weread, :reminder_needed?, -> { needed }, &block)
  end

  test "skips silently when feishu is not configured" do
    stub_feishu(enabled: false) do
      # reminder_needed? 都不该被问，更不该去取二维码
      stub_class_method(QrLogin::Weread, :reminder_needed?, -> { raise "不应被调用" }) do
        FeishuLoginReminderJob.perform_now("weread")
      end
    end

    assert_empty @sent
  end

  test "skips when the provider says no reminder is needed" do
    stub_feishu do
      stub_provider(needed: false) do
        stub_class_method(QrLogin::Weread, :start, -> { raise "不应获取二维码" }) do
          FeishuLoginReminderJob.perform_now("weread")
        end
      end
    end

    assert_empty @sent
  end

  test "card mode pushes an interactive card and does not fetch a QR" do
    Option.feishu_login_mode = "card"

    stub_feishu do
      stub_provider(needed: true) do
        stub_class_method(QrLogin::Weread, :start, -> { raise "卡片模式不应获取二维码" }) do
          FeishuLoginReminderJob.perform_now("weread")
        end
      end
    end

    assert_equal 1, @sent.size
    kind, card = @sent.first
    assert_equal :card, kind
    # 卡片按钮的 action 必须是回调能反查到的值
    action = card[:elements].last[:actions].first[:value][:action]
    assert_equal QrLogin::Weread, QrLogin.find_by_card_action(action)
  end

  test "qr mode pushes the QR then reports the login result" do
    Option.feishu_login_mode = "qr"
    handle = { "uuid" => "u1" }
    payload = { "vid" => "v9", "token" => "t9", "username" => "读书人" }

    stub_feishu do
      stub_provider(needed: true) do
        stub_class_methods(
          QrLogin::Weread,
          start: -> { { handle: handle, image_bytes: "PNG", image_mime: "image/png" } },
          poll: proc { |*, **| { status: :success, message: "登录成功", handle: handle, result: payload } }
        ) do
          FeishuLoginReminderJob.perform_now("weread")
        end
      end
    end

    assert_equal [ :qr, :text ], @sent.map(&:first)
    assert_match "✅", @sent.last[1]
    assert_match "读书人", @sent.last[1]
    assert_equal "v9", Option.weread_accounts.first["vid"], "登录成功必须落库到账号池"
  end

  test "qr mode reports an expired QR without blowing up the job" do
    Option.feishu_login_mode = "qr"

    stub_feishu do
      stub_provider(needed: true) do
        stub_class_methods(
          QrLogin::Weread,
          start: -> { { handle: { "uuid" => "u1" }, image_bytes: "PNG", image_mime: "image/png" } },
          poll: proc { |*, **| { status: :expired, message: "二维码已过期", handle: {}, result: nil } }
        ) do
          FeishuLoginReminderJob.perform_now("weread")
        end
      end
    end

    assert_equal [ :qr, :text ], @sent.map(&:first)
    assert_match "已过期", @sent.last[1]
  end

  test "unknown provider keys are logged, not raised" do
    assert_nothing_raised { FeishuLoginReminderJob.perform_now("nope") }
  end

  # wechat_mp is deliberately left out of the daily schedule (8ec0da9); it stays
  # commented out in recurring.yml rather than deleted. So don't pin the exact
  # set of platforms here — what must hold is that every key we do schedule
  # resolves to a real QrLogin provider, since a typo would only surface as a
  # silent no-op at 9:30am.
  test "recurring schedule only wires platform keys this job understands" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"))
    entries = schedule["production"].values.select { |e| e["class"] == "FeishuLoginReminderJob" }
    platform_keys = entries.flat_map { |e| e["args"] }

    assert_includes platform_keys, "weread"
    platform_keys.each { |key| assert_nothing_raised { QrLogin.find(key) } }
  end
end
