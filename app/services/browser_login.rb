# 远程浏览器登录（BrowserLogin）。
#
# Docker 部署时无法在服务器上打开真实浏览器来扫码/输密码。这里用一个受管理的
# Chromium 进程（持久化 user-data-dir）承载登录页面，设置页通过 Rails 端点
# 轮询截图、转发点击/键盘事件，从而在浏览器里"遥控"完成登录；成功后把
# Cookie 落到 Option 的会话槽位（与 QrLogin 同一套存储约定）。
#
# 各平台的登录地址与凭据导出逻辑见 BrowserLogin::Base 的子类；
# 会话生命周期见 BrowserLogin::Session。
module BrowserLogin
  PROVIDERS = {
    "wechat_mp" => BrowserLogin::WechatMp,
    "rednote_web" => BrowserLogin::RednoteWeb,
    "weread_native" => BrowserLogin::WereadNative
  }.freeze

  class Error < StandardError
  end

  module_function

  def find(key)
    PROVIDERS.fetch(key.to_s) { raise Error, "未知的远程登录平台: #{key}" }
  end

  # 各平台持久化浏览器环境（user-data-dir）的根目录。人工登录与正文抓取
  # 共用同一环境，验证/登录产生的 Cookie 因此可以在两者之间生效。
  def profile_root
    Rails.root.join("storage", "browser_profiles")
  end

  def profile_dir_for(provider_key)
    profile_root.join(provider_key).to_s
  end
end
