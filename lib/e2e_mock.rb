# E2E 浏览器回归测试的离线 mock 层。
#
# bin/e2e 以 E2E_MOCKS=1 启动 development 服务器时由
# config/initializers/e2e_mock.rb 调 E2EMock.enable! 激活：
#
#   1. WebMock 拦截所有外部 HTTP（按 host 分发给 Handlers），回放
#      e2e/fixtures/ 下的本地报文——mp.weixin.qq.com 的扫码登录、文章列表、
#      文章正文都是真实响应结构，因此客户端解析/清洗/落库逻辑原样运行。
#   2. 少数不走 HTTP 的依赖在 Ruby 层 stub（见 RubyStubs）：
#      TwitterApiClient（python3 子进程）、WechatArticleBrowserFetcher（Ferrum 真浏览器）。
#   3. 未被 mock 的外部 host 会直接抛 WebMock::NetConnectNotAllowedError，
#      保证测试永不触网，也暴露出新引入的外部依赖。
#
# 只在 development 环境可启用；生产与测试套件完全不受影响。
module E2EMock
  FIXTURE_ROOT = Rails.root.join("e2e/fixtures").freeze
  SAMPLE_ROOT  = Rails.root.join("e2e/fixtures/samples").freeze

  class UnmockedRequest < StandardError; end

  def self.enabled?
    Rails.env.development? && ENV["E2E_MOCKS"] == "1"
  end

  def self.enable!
    require "webmock"
    require_relative "e2e_mock/handlers"
    require_relative "e2e_mock/registry"
    require_relative "e2e_mock/ruby_stubs"

    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)

    Registry.register!
    RubyStubs.apply!

    Rails.logger.info("[E2EMock] 已启用：外部 HTTP 由 #{FIXTURE_ROOT} 回放")
  end

  # 读取 fixture；优先 samples/（生产样本，gitignore，不提交），
  # 缺失时回退到仓库内置的合成 fixture。name 是相对路径，如
  # "wechat_mp/free_publish/3876543210.json"。
  def self.fixture(name)
    sample = SAMPLE_ROOT.join(name)
    path = sample.exist? ? sample : FIXTURE_ROOT.join(name)
    raise UnmockedRequest, "E2E fixture 缺失: #{path}（host 请求落到了没有 fixture 的端点）" unless path.exist?

    File.binread(path)
  end

  def self.fixture_exist?(name)
    SAMPLE_ROOT.join(name).exist? || FIXTURE_ROOT.join(name).exist?
  end
end
