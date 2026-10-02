module E2EMock
  # 把 WebMock 拦到的请求按 host 分发给 Handlers，并把返回值适配成
  # WebMock 的 to_return 响应 Hash。未知 host 不注册（WebMock 直接报
  # NetConnectNotAllowedError），让新引入的外部依赖在 E2E 里立刻暴露。
  module Registry
    HOSTS = {
      "mp.weixin.qq.com" => Handlers::WechatMp,
      "www.dajiala.com"  => Handlers::Dajiala,
      "api.tikhub.io"    => Handlers::TikHub,
      "api.yddm.com"     => Handlers::Rednote,
      "weread.qq.com"    => Handlers::WereadNative,
      "open.feishu.cn"   => Handlers::Feishu,
      # 活动调研（event research）
      "google.serper.dev"              => Handlers::Serper,
      "open.api.tianyancha.com"        => Handlers::Tianyancha,
      "openai-proxy.miracleplus.com"   => Handlers::LlmProxy,
      "news.e2e-event.test"            => Handlers::EventWeb
    }.freeze

    class << self
      def register!
        HOSTS.each do |host, handler|
          WebMock.stub_request(:any, /#{Regexp.escape(host)}/).to_return do |request|
            respond(handler, request)
          end
        end
      end

      def respond(handler, request)
        response = handler.handle(request) ||
                   raise(UnmockedRequest,
                         "[E2EMock] #{handler} 没有为 #{request.method.upcase} #{request.uri} 提供 fixture")

        {
          status: response.fetch(:status, 200),
          headers: (response[:headers] || {}).merge("X-E2E-Mock" => "1"),
          body: response[:body].to_s
        }
      rescue UnmockedRequest => e
        { status: 599, headers: { "Content-Type" => "application/json; charset=utf-8" },
          body: { error: e.message }.to_json }
      end
    end
  end
end
