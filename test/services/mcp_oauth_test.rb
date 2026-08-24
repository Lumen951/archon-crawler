require "test_helper"

class McpOauthTest < ActiveSupport::TestCase
  # The Doorkeeper initializer cannot reference McpOauth (autoloading during
  # boot), so the scope names live in two places. Catch them drifting apart.
  test "configured Doorkeeper scopes match the ones the resource server enforces" do
    assert_equal McpOauth::SCOPES.sort, Doorkeeper.config.scopes.to_a.sort
    assert_includes Doorkeeper.config.default_scopes.to_a, McpOauth::READ_SCOPE
    assert_includes Doorkeeper.config.optional_scopes.to_a, McpOauth::WRITE_SCOPE
  end

  test "every write tool has a description on the consent screen" do
    assert McpOauth::SCOPE_DESCRIPTIONS.key?(McpOauth::READ_SCOPE)
    assert McpOauth::SCOPE_DESCRIPTIONS.key?(McpOauth::WRITE_SCOPE)
  end

  test "write tools are recognised and read tools are not" do
    assert McpOauth.write_tool?("update_accounts")
    assert McpOauth.write_tool?("batch_update_accounts_by_filter")
    assert_not McpOauth.write_tool?("list_accounts")
    assert_not McpOauth.write_tool?(nil)
  end

  test "canonical resource identifier has no trailing slash" do
    assert_equal "https://example.com/mcp/endpoint", McpOauth.resource_identifier("https://example.com")
    assert_equal "https://example.com/mcp/endpoint", McpOauth.resource_identifier("https://example.com/")
  end

  test "resource matching accepts uppercase scheme and host but not a different resource" do
    base = "https://example.com"

    assert McpOauth.matches_resource?("https://example.com/mcp/endpoint", base)
    assert McpOauth.matches_resource?("HTTPS://EXAMPLE.COM/mcp/endpoint", base)
    assert McpOauth.matches_resource?("https://example.com:443/mcp/endpoint", base)
    assert_not McpOauth.matches_resource?("https://example.com/other", base)
    assert_not McpOauth.matches_resource?("https://attacker.example/mcp/endpoint", base)
    assert_not McpOauth.matches_resource?("example.com/mcp/endpoint", base)
    assert_not McpOauth.matches_resource?("", base)
  end

  test "redirect uris allow https anywhere and http only on loopback" do
    assert McpOauth.acceptable_redirect_uri?("https://app.example.com/callback")
    assert McpOauth.acceptable_redirect_uri?("http://127.0.0.1:8976/callback")
    assert McpOauth.acceptable_redirect_uri?("http://localhost:3000/cb")
    assert_not McpOauth.acceptable_redirect_uri?("http://example.com/callback")
    assert_not McpOauth.acceptable_redirect_uri?("myapp://callback")
    assert_not McpOauth.acceptable_redirect_uri?("javascript:alert(1)")
    assert_not McpOauth.acceptable_redirect_uri?("")
  end

  test "challenge omits the error code when no credentials were presented" do
    challenge = McpOauth.challenge("https://example.com")

    assert_equal(
      %(Bearer resource_metadata="https://example.com/.well-known/oauth-protected-resource/mcp/endpoint", scope="mcp:read mcp:write"),
      challenge
    )
  end

  test "challenge carries the error code and narrowed scope for a step-up" do
    challenge = McpOauth.challenge(
      "https://example.com",
      error: "insufficient_scope",
      error_description: "needs write",
      scope: McpOauth::WRITE_SCOPE
    )

    assert_includes challenge, %(error="insufficient_scope")
    assert_includes challenge, %(error_description="needs write")
    assert_includes challenge, %(scope="mcp:write")
  end
end
