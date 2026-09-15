require "bigdecimal"

# 单次抓取运行期间的第三方 API 计费累计（按次消耗 + 厂商返回的账户余额）。
#
# 由 CrawlTask 实例持有：一个 CrawlTask 对象对应一次 CrawlOrchestrator 运行，
# 所以不需要按任务 id 注册与清理 —— 运行结束对象被回收，累计值随之消失；
# 暂停后恢复的任务会重新查出对象、拿到全新的累计器，不会把上一次运行的数字叠加进来。
#
# 各平台帐号在同一进程内用 Async 协程并发抓取，故用 Mutex 保护（与 RateLimiter 同一约定）。
class ApiUsageTally
  Entry = Struct.new(:calls, :cost, :balance, :first_balance, keyword_init: true)

  def initialize
    @platforms = {}
    @mutex = Mutex.new
  end

  # 记录一次调用。
  # @param platform_key [String] Account 子类名，如 "RednoteAccount"
  # @param cost [Numeric, nil] 本次消耗的积分，nil 表示厂商未上报（与 0 区分）
  # @param balance [Numeric, nil] 本次调用后的剩余积分
  def record(platform_key, cost: nil, balance: nil)
    @mutex.synchronize do
      entry = (@platforms[platform_key.to_s] ||= Entry.new(calls: 0))
      # 金额未上报也要计调用次数
      entry.calls += 1
      entry.cost = (entry.cost || 0) + cost if cost
      if balance
        entry.first_balance ||= balance
        entry.balance = balance
      end
    end
  end

  # @return [Hash, nil] { calls:, cost:, balance:, first_balance: }；该平台从未记录过时返回 nil
  def totals_for(platform_key)
    @mutex.synchronize do
      entry = @platforms[platform_key.to_s]
      next nil unless entry

      {
        calls: entry.calls,
        cost: entry.cost,
        balance: entry.balance,
        first_balance: entry.first_balance
      }
    end
  end

  # 渲染积分：整数值不带小数点，小数值原样保留（不 round、不截断）。
  # BigDecimal 要用 "F" 格式，否则 to_s 会输出 "0.125e2" 这种科学计数法。
  def self.format_credits(value)
    return nil if value.nil?
    return value.to_i.to_s if value == value.to_i

    value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s
  end
end
