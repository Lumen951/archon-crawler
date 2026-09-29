class ApplicationController < ActionController::Base
  add_flash_types :success, :error

  include Authentication
  include Authorization

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # CSRF 校验失败（典型：部署后沿用旧标签页，页面里的 token 与当前会话对不上）。
  # 默认渲染 422 HTML，XHR 拿到后 resp.json() 只会报
  # "Unexpected token '<'"（生产踩过）；对 XHR 返回 JSON 给出可操作提示。
  rescue_from ActionController::InvalidAuthenticityToken, with: :handle_csrf_failure

  private

  def handle_csrf_failure(exception)
    raise exception unless request.xhr?

    render json: { error: "页面已过期（安全校验失败），请刷新页面后重试" }, status: :unprocessable_entity
  end
end
