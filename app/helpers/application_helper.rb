module ApplicationHelper
  # 侧边栏高亮判断：精确匹配或路径前缀匹配（/accounts 同时命中 /accounts/123）
  def nav_active?(*paths)
    paths.any? { |p| request.path == p || request.path.start_with?("#{p}/") }
  end
end
