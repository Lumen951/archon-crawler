# E2E 浏览器回归测试的离线 mock 模式（bin/e2e 注入 E2E_MOCKS=1 时激活）。
# 仅 development 环境生效；生产与测试套件不受影响。实现见 lib/e2e_mock.rb。
if Rails.env.development? && ENV["E2E_MOCKS"] == "1"
  require "e2e_mock"
  E2eMock.enable!
end
