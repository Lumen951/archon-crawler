# frozen_string_literal: true

require "test_helper"

class ApiUsageTallyTest < ActiveSupport::TestCase
  setup do
    @tally = ApiUsageTally.new
  end

  test "从未记录过的平台返回 nil" do
    assert_nil @tally.totals_for("RednoteAccount")
  end

  test "按平台累计调用次数、消耗与余额" do
    @tally.record("RednoteAccount", cost: 100, balance: 9_982_100)
    @tally.record("RednoteAccount", cost: 20, balance: 9_982_080)

    totals = @tally.totals_for("RednoteAccount")

    assert_equal 2, totals[:calls]
    assert_equal 120, totals[:cost]
    assert_equal 9_982_080, totals[:balance]
    assert_equal 9_982_100, totals[:first_balance]
  end

  test "不同平台分开累计" do
    @tally.record("RednoteAccount", cost: 100, balance: 1)
    @tally.record("WechatAccount", cost: 5, balance: 2)

    assert_equal 100, @tally.totals_for("RednoteAccount")[:cost]
    assert_equal 5, @tally.totals_for("WechatAccount")[:cost]
  end

  test "厂商未上报金额时仍计调用次数，且不伪造 0" do
    @tally.record("RednoteAccount")

    totals = @tally.totals_for("RednoteAccount")

    assert_equal 1, totals[:calls]
    assert_nil totals[:cost]
    assert_nil totals[:balance]
  end

  test "未知余额不会覆盖已记录的真实余额" do
    @tally.record("RednoteAccount", cost: 100, balance: 9_982_100)
    @tally.record("RednoteAccount", cost: 20)

    assert_equal 9_982_100, @tally.totals_for("RednoteAccount")[:balance]
  end

  test "format_credits 不截断小数、不给整数加小数点" do
    assert_nil ApiUsageTally.format_credits(nil)
    assert_equal "1200", ApiUsageTally.format_credits(1200)
    assert_equal "12.5", ApiUsageTally.format_credits(12.5)
    assert_equal "12.5", ApiUsageTally.format_credits(BigDecimal("12.5"))
    assert_equal "1200", ApiUsageTally.format_credits(BigDecimal("1200"))
  end
end
