Rails.application.configure do
  MissionControl::Jobs.http_basic_auth_enabled = false
  MissionControl::Jobs.base_controller_class = "Admin::BaseController"
end
