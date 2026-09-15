# frozen_string_literal: true

require "test_helper"

class RednoteApiClientTest < ActiveSupport::TestCase
  # 打桩传输层：handle_response 只用到 response.status / response.body
  def stub_api(body, status: 200)
    response = Struct.new(:status, :body).new(status, body.to_json)
    connection = Struct.new(:response) do
      def post(*_args) = response
    end.new(response)

    stub_class_methods(RednoteApiClient, connection: -> { connection }, headers: -> { {} }) do
      yield
    end
  end

  test "从 data 内读取消耗与余额，且返回值仍是原来的 data" do
    usage = nil
    data = nil

    stub_api({ code: 0, data: { cost: 100, balance: 9_982_100, notes: [ { "noteId" => "n1" } ] } }) do
      data = RednoteApiClient.get_user_notes("user1", page: 1) { |u| usage = u }
    end

    assert_equal 100, usage.cost
    assert_equal 9_982_100, usage.balance
    assert_equal "n1", data["notes"].first["noteId"]
  end

  test "顶层放置 cost / balance 时也能读取" do
    usage = nil

    stub_api({ code: 0, cost: 7, balance: 42, data: { notes: [] } }) do
      RednoteApiClient.get_user_notes("user1") { |u| usage = u }
    end

    assert_equal 7, usage.cost
    assert_equal 42, usage.balance
  end

  test "响应没有计费字段时不触发回调" do
    called = false

    stub_api({ code: 0, data: { notes: [] } }) do
      RednoteApiClient.get_user_notes("user1") { |_u| called = true }
    end

    assert_not called
  end

  test "余额不足（code 1001）时先上报用量再抛错" do
    usage = nil

    stub_api({ code: 1001, msg: "余额不足", data: { cost: 100, balance: 0 } }) do
      assert_raises(RednoteApiClient::ApiInsufficientBalanceError) do
        RednoteApiClient.get_user_notes("user1") { |u| usage = u }
      end
    end

    assert_equal 100, usage.cost
    assert_equal 0, usage.balance
  end

  test "应用层限流（code 429）时先上报用量再抛错" do
    usage = nil

    stub_api({ code: 429, data: { cost: 100, balance: 500 } }) do
      assert_raises(RednoteApiClient::ApiRateLimitError) do
        RednoteApiClient.get_note_detail("note1") { |u| usage = u }
      end
    end

    assert_equal 100, usage.cost
  end

  test "字符串形式的金额不被截断" do
    usage = nil

    stub_api({ code: 0, data: { cost: "12.5", balance: "9982087.5" } }) do
      RednoteApiClient.get_note_detail("note1") { |u| usage = u }
    end

    assert_equal BigDecimal("12.5"), usage.cost
    assert_equal "12.5", ApiUsageTally.format_credits(usage.cost)
    assert_equal "9982087.5", ApiUsageTally.format_credits(usage.balance)
  end

  # 回调里的异常若逃逸出去，会被 Retryable.with_retry 当成"调用失败"而重试 —— 厂商重复计费
  test "回调抛异常不会把成功的调用变成失败" do
    data = nil

    stub_api({ code: 0, data: { cost: 1, balance: 2, notes: [] } }) do
      data = RednoteApiClient.get_user_notes("user1") { |_u| raise "callback boom" }
    end

    assert_equal [], data["notes"]
  end

  test "非 200 响应不触发回调" do
    [
      [ 401, RednoteApiClient::ApiKeyMissingError ],
      [ 403, RednoteApiClient::ApiKeyMissingError ],
      [ 500, RednoteApiClient::ApiError ]
    ].each do |status, error|
      called = false

      stub_api({ cost: 1, balance: 2 }, status: status) do
        assert_raises(error) do
          RednoteApiClient.get_user_notes("user1") { |_u| called = true }
        end
      end

      assert_not called, "HTTP #{status} 不应触发用量回调"
    end
  end

  test "validate_key 不受计费上报影响" do
    stub_api({ code: 0, data: { cost: 100, balance: 9_982_100 } }) do
      assert RednoteApiClient.validate_key
    end
  end
end
