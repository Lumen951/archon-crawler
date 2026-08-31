require "test_helper"
require "stringio"
require "logger"

class FeishuLoginForUserJobTest < ActiveSupport::TestCase
  setup do
    @logs = []
    @open_id = "ou_sensitive_recipient_123"
    @session = {
      handle: { "uuid" => "uuid-sensitive", "cookie_jar" => { "session" => "secret-cookie" } },
      image_bytes: "PNGDATA",
      image_mime: "image/png"
    }
  end

  test "logs the complete successful flow without exposing recipient or handle values" do
    provider = QrLogin::Weread
    session = @session
    poll = proc { |_handle, **| { status: :success, result: { "token" => "secret-token" }, message: "登录成功" } }
    logger = logger_stub

    stub_class_methods(
      QrLogin,
      find: ->(_key) { provider }
    ) do
      stub_class_methods(
        provider,
        start: -> { session },
        poll: poll,
        save_success!: ->(_result) { "读书人" },
        key: -> { "weread" },
        label: -> { "微信读书" }
      ) do
        stub_class_methods(
          FeishuNotifier,
          send_qr_login_to: ->(**) {},
          send_text: ->(*, **) {}
        ) do
          stub_class_method(Rails, :logger, -> { logger }) { FeishuLoginForUserJob.perform_now("weread", @open_id) }
        end
      end
    end

    output = logger.captured_output.lines.select { |line| line.include?("[FeishuLoginForUserJob]") }.join
    assert_includes output, "qr creation complete"
    assert_includes output, "poll attempt=1 result status=:success"
    assert_includes output, "save_success complete identity_present=true"
    assert_includes output, "final notification complete"
    assert_includes output, "recipient_sha="
    assert_not_includes output, @open_id
    assert_not_includes output, "uuid-sensitive"
    assert_not_includes output, "secret-cookie"
    assert_not_includes output, "secret-token"
  end

  private

  def logger_stub
    io = StringIO.new
    Logger.new(io).tap do |logger|
      logger.level = Logger::DEBUG
      logger.define_singleton_method(:captured_output) { io.string }
    end
  end
end
