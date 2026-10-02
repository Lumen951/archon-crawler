# 断点续跑用的磁盘缓存：一个 key 一个 JSON 文件，写盘走 tmp + rename（原子替换）。
# 仓库里没有可复用的磁盘缓存抽象（Rails.cache 在开发环境是 memory_store，进程退出即失效），
# 所以自带这一层。CLI 与应用内共用，root 由调用方给定（应用内位于 tmp/event_research/ 下）。
class EventResearch::RunCache
  MISS = Object.new

  def initialize(root:, reporter:, refresh: false)
    @root = root.to_s
    @reporter = reporter
    @refresh = refresh
    @stats = Hash.new { |hash, key| hash[key] = { "hit" => 0, "miss" => 0, "write" => 0 } }
  end

  attr_reader :root

  # 命中且在 TTL 内的直接返回；否则执行块并写盘。
  # cache_if 用来决定「这次的结果值不值得缓存」——失败结果不缓存，下次重跑会重试。
  def wrap(namespace, key, ttl:, label: nil, cache_if: nil)
    unless @refresh
      cached = read(namespace, key, ttl: ttl)
      unless cached.equal?(MISS)
        @stats[namespace]["hit"] += 1
        @reporter.debug("缓存命中 #{namespace}: #{label || key}")
        return cached
      end
    end

    @stats[namespace]["miss"] += 1
    value = yield

    if cache_if.nil? || cache_if.call(value)
      write(namespace, key, value, label: label)
      @stats[namespace]["write"] += 1
    end

    value
  end

  def read(namespace, key, ttl:)
    path = path_for(namespace, key)
    return MISS unless File.exist?(path)

    entry = JSON.parse(File.read(path))
    cached_at = Time.parse(entry["cached_at"].to_s)
    return MISS if Time.current - cached_at > ttl

    entry["value"]
  rescue JSON::ParserError, ArgumentError, TypeError => e
    # 写到一半 / 被手改坏的文件当作没有缓存，重算即可
    @reporter.warn("缓存文件损坏，忽略: #{path}（#{e.class}）")
    MISS
  end

  def write(namespace, key, value, label: nil)
    path = path_for(namespace, key)
    # 带随机后缀：并发抓取时同一 key 万一同时落盘，两个任务也不会写/rename 同一个临时文件
    tmp = "#{path}.#{Process.pid}.#{rand(1 << 32).to_s(36)}.tmp"

    FileUtils.mkdir_p(File.dirname(path))
    File.write(tmp, JSON.generate({ "cached_at" => Time.current.iso8601, "label" => label, "value" => value }))
    File.rename(tmp, path)
  rescue SystemCallError, JSON::GeneratorError => e
    # 缓存写不进去不该让整轮调研失败
    @reporter.warn("缓存写入失败: #{path}（#{e.class}: #{e.message}）")
  end

  # 覆盖所有 namespace（没算过的补 0），这样写进 metadata 的统计是稳定的形状
  def stats
    EventResearch::CACHE_TTLS.keys.to_h { |namespace| [ namespace, @stats[namespace].dup ] }
  end

  def summary
    return "无缓存记录" if @stats.empty?

    @stats.map { |namespace, counts| "#{namespace} #{counts["hit"]} 命中/#{counts["miss"]} 未命中" }.join("，")
  end

  private

  def path_for(namespace, key)
    File.join(@root, "cache", namespace, "#{Digest::SHA256.hexdigest(key.to_s)}.json")
  end
end
