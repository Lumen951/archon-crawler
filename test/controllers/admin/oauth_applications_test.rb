require "test_helper"

module Admin
  class OauthApplicationsTest < ActionDispatch::IntegrationTest
    setup do
      @admin = User.create!(
        email_address: "oauth-admin@example.com",
        password: "password123",
        password_confirmation: "password123",
        role: :admin,
        email_confirmed_at: Time.current
      )
      post session_path, params: { email_address: @admin.email_address, password: "password123" }
    end

    test "index lists registered OAuth clients with their token counts" do
      application = Doorkeeper::Application.create!(
        name: "Claude Code",
        redirect_uri: "http://127.0.0.1:8976/callback",
        scopes: "mcp:read mcp:write",
        confidential: false
      )
      Doorkeeper::AccessToken.create!(
        application: application,
        resource_owner_id: @admin.id,
        scopes: "mcp:read",
        expires_in: 2.hours,
        resource: "http://www.example.com/mcp/endpoint"
      )

      get admin_oauth_applications_path

      assert_response :success
      assert_match "Claude Code", response.body
      assert_match application.uid, response.body
    end

    test "destroy revokes the client and cascades to its tokens" do
      application = Doorkeeper::Application.create!(
        name: "Codex",
        redirect_uri: "http://127.0.0.1:8976/callback",
        scopes: "mcp:read",
        confidential: false
      )
      Doorkeeper::AccessToken.create!(
        application: application,
        resource_owner_id: @admin.id,
        scopes: "mcp:read",
        expires_in: 2.hours,
        resource: "http://www.example.com/mcp/endpoint"
      )

      assert_difference "Doorkeeper::Application.count", -1 do
        assert_difference "Doorkeeper::AccessToken.count", -1 do
          delete admin_oauth_application_path(application)
        end
      end

      assert_redirected_to admin_oauth_applications_path
    end

    test "non-admin users are denied" do
      Doorkeeper::Application.create!(
        name: "Claude Code",
        redirect_uri: "http://127.0.0.1:8976/callback",
        scopes: "mcp:read",
        confidential: false
      )
      post session_path, params: { email_address: @admin.email_address, password: "password123" }

      # downgrade to a regular user and try again
      @admin.update!(role: :user)
      delete session_path

      regular = User.create!(
        email_address: "regular@example.com",
        password: "password123",
        password_confirmation: "password123",
        email_confirmed_at: Time.current
      )
      post session_path, params: { email_address: regular.email_address, password: "password123" }

      get admin_oauth_applications_path

      assert_redirected_to root_path
    end
  end
end
