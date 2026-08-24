require "test_helper"

# Exercises the path an MCP client (Claude Code, Codex, ...) walks on its own:
# 401 challenge -> metadata discovery -> dynamic registration -> PKCE
# authorization -> token -> tool call.
class McpOauthFlowTest < ActionDispatch::IntegrationTest
  MCP_HEADERS = {
    "Content-Type" => "application/json",
    "Accept" => "application/json, text/event-stream"
  }.freeze

  REDIRECT_URI = "http://127.0.0.1:8976/callback".freeze
  BASE_URL     = "http://www.example.com".freeze
  RESOURCE     = "#{BASE_URL}/mcp/endpoint".freeze

  setup do
    @user = User.create!(
      email_address: "mcp_oauth@example.com",
      password: "password123",
      password_confirmation: "password123",
      email_confirmed_at: Time.current
    )
  end

  # --- discovery -------------------------------------------------------------

  test "an unauthenticated MCP request points the client at the metadata document" do
    post "/mcp/endpoint", params: rpc(method: "tools/list"), headers: MCP_HEADERS

    assert_response :unauthorized
    challenge = response.headers["WWW-Authenticate"]
    assert_includes challenge, %(resource_metadata="#{BASE_URL}/.well-known/oauth-protected-resource/mcp/endpoint")
    assert_includes challenge, %(scope="mcp:read mcp:write")
    # RFC 6750 §3: no error code when the request carried no credentials at all.
    assert_not_includes challenge, "error="
  end

  test "an invalid token is challenged with invalid_token" do
    post "/mcp/endpoint", params: rpc(method: "tools/list"),
         headers: MCP_HEADERS.merge("Authorization" => "Bearer nonsense")

    assert_response :unauthorized
    assert_includes response.headers["WWW-Authenticate"], %(error="invalid_token")
  end

  test "protected resource metadata names this authorization server" do
    get "/.well-known/oauth-protected-resource/mcp/endpoint"

    assert_response :success
    body = response.parsed_body
    assert_equal RESOURCE, body["resource"]
    assert_equal [ BASE_URL ], body["authorization_servers"]
    assert_equal [ "mcp:read", "mcp:write" ], body["scopes_supported"]
    assert_equal [ "header" ], body["bearer_methods_supported"]
  end

  test "protected resource metadata is also served at the bare well-known path" do
    get "/.well-known/oauth-protected-resource"

    assert_response :success
    assert_equal RESOURCE, response.parsed_body["resource"]
  end

  test "protected resource metadata 404s for a resource this host does not serve" do
    get "/.well-known/oauth-protected-resource/some/other/resource"

    assert_response :not_found
  end

  test "authorization server metadata advertises PKCE, refresh and registration" do
    get "/.well-known/oauth-authorization-server"

    assert_response :success
    body = response.parsed_body
    assert_equal BASE_URL, body["issuer"]
    assert_equal "#{BASE_URL}/oauth/authorize", body["authorization_endpoint"]
    assert_equal "#{BASE_URL}/oauth/token", body["token_endpoint"]
    assert_equal "#{BASE_URL}/oauth/register", body["registration_endpoint"]
    assert_equal [ "S256" ], body["code_challenge_methods_supported"]
    assert_includes body["grant_types_supported"], "refresh_token"
    assert_includes body["token_endpoint_auth_methods_supported"], "none"
  end

  # --- dynamic client registration -------------------------------------------

  test "dynamic client registration issues a public client with no secret" do
    body = register_client(client_name: "Claude Code")

    assert_response :created
    assert body["client_id"].present?
    assert_nil body["client_secret"]
    assert_equal "none", body["token_endpoint_auth_method"]
    assert_equal [ REDIRECT_URI ], body["redirect_uris"]
    assert_equal "Claude Code", body["client_name"]
  end

  test "dynamic client registration issues a secret when the client asks to authenticate" do
    body = register_client(token_endpoint_auth_method: "client_secret_post")

    assert_response :created
    assert body["client_secret"].present?
    assert_equal "client_secret_post", body["token_endpoint_auth_method"]
  end

  # ChatGPT's connector registration omits `scope` entirely and then asks for
  # every advertised scope at /oauth/authorize. Registering it read-only used to
  # make that authorization request fail with invalid_scope.
  test "a client that omits scope at registration is registered for every advertised scope" do
    body = register_client(scope: nil)

    assert_response :created
    assert_equal "mcp:read mcp:write", body["scope"]
  end

  test "a client that omits scope at registration can still authorize for write" do
    client = register_client(scope: nil)
    verifier = SecureRandom.urlsafe_base64(64)
    sign_in

    get "/oauth/authorize", params: authorize_params(client, verifier)

    assert_response :success
    assert_match "授权 MCP 客户端", response.body
  end

  test "dynamic client registration refuses plain http outside loopback" do
    register_client(redirect_uris: [ "http://evil.example.com/callback" ])

    assert_response :bad_request
    assert_equal "invalid_redirect_uri", response.parsed_body["error"]
  end

  test "dynamic client registration requires at least one redirect uri" do
    register_client(redirect_uris: [])

    assert_response :bad_request
    assert_equal "invalid_redirect_uri", response.parsed_body["error"]
  end

  # --- authorization code + PKCE ---------------------------------------------

  test "a client can register, authorize with PKCE and then call a tool" do
    client = register_client
    verifier = SecureRandom.urlsafe_base64(64)
    sign_in

    get "/oauth/authorize", params: authorize_params(client, verifier)
    assert_response :success
    assert_match "授权 MCP 客户端", response.body

    post "/oauth/authorize", params: authorize_params(client, verifier)
    assert_response :redirect

    redirect = URI.parse(response.location)
    query = Rack::Utils.parse_query(redirect.query)
    assert_equal "127.0.0.1", redirect.host
    assert_equal "xyz-state", query["state"]
    assert query["code"].present?

    post "/oauth/token", params: {
      grant_type: "authorization_code",
      code: query["code"],
      redirect_uri: REDIRECT_URI,
      client_id: client["client_id"],
      code_verifier: verifier,
      resource: RESOURCE
    }

    assert_response :success
    token = response.parsed_body
    assert_equal "Bearer", token["token_type"]
    assert_equal 7200, token["expires_in"]
    assert token["refresh_token"].present?

    # The token carries its RFC 8707 audience binding.
    access_token = Doorkeeper::AccessToken.by_token(token["access_token"])
    assert_equal RESOURCE, access_token.resource
    assert_equal @user.id, access_token.resource_owner_id

    post "/mcp/endpoint", params: rpc(method: "tools/list"),
         headers: MCP_HEADERS.merge("Authorization" => "Bearer #{token["access_token"]}")

    assert_response :success
    assert response.parsed_body.dig("result", "tools").present?
  end

  test "authorization without PKCE is refused" do
    client = register_client
    sign_in

    params = authorize_params(client, SecureRandom.urlsafe_base64(64))
    params.delete(:code_challenge)
    params.delete(:code_challenge_method)

    get "/oauth/authorize", params: params

    assert_response :bad_request
  end

  test "authorization is refused for a resource this server does not host" do
    client = register_client
    sign_in

    get "/oauth/authorize", params: authorize_params(client, SecureRandom.urlsafe_base64(64))
                              .merge(resource: "https://elsewhere.example.com/mcp")

    assert_response :bad_request
    assert_equal "invalid_target", response.parsed_body["error"]
  end

  test "the authorization endpoint sends anonymous visitors through login first" do
    client = register_client

    get "/oauth/authorize", params: authorize_params(client, SecureRandom.urlsafe_base64(64))

    assert_redirected_to new_session_path
  end

  # --- resource server behaviour ---------------------------------------------

  test "a read-only token is refused for a mutating tool" do
    access_token = issue_token(scopes: "mcp:read")

    post "/mcp/endpoint",
         params: rpc(method: "tools/call", params: { name: "update_accounts", arguments: { account_ids: [ 1 ], status: "inactive" } }),
         headers: MCP_HEADERS.merge("Authorization" => "Bearer #{access_token.plaintext_token}")

    assert_response :forbidden
    challenge = response.headers["WWW-Authenticate"]
    assert_includes challenge, %(error="insufficient_scope")
    assert_includes challenge, %(scope="mcp:write")
  end

  test "a read-only token may call a read tool" do
    access_token = issue_token(scopes: "mcp:read")

    post "/mcp/endpoint",
         params: rpc(method: "tools/call", params: { name: "list_tags", arguments: {} }),
         headers: MCP_HEADERS.merge("Authorization" => "Bearer #{access_token.plaintext_token}")

    assert_response :success
  end

  test "a write-scoped token may call a mutating tool" do
    access_token = issue_token(scopes: "mcp:read mcp:write")

    post "/mcp/endpoint",
         params: rpc(method: "tools/call", params: { name: "update_accounts", arguments: { account_ids: [], status: "inactive" } }),
         headers: MCP_HEADERS.merge("Authorization" => "Bearer #{access_token.plaintext_token}")

    assert_response :success
  end

  test "an expired token is refused" do
    access_token = issue_token(scopes: "mcp:read")
    access_token.update!(created_at: 3.hours.ago, expires_in: 3600)

    post "/mcp/endpoint", params: rpc(method: "tools/list"),
         headers: MCP_HEADERS.merge("Authorization" => "Bearer #{access_token.plaintext_token}")

    assert_response :unauthorized
    assert_includes response.headers["WWW-Authenticate"], %(error="invalid_token")
  end

  test "a token minted for another resource is refused" do
    access_token = issue_token(scopes: "mcp:read", resource: "https://elsewhere.example.com/mcp")

    post "/mcp/endpoint", params: rpc(method: "tools/list"),
         headers: MCP_HEADERS.merge("Authorization" => "Bearer #{access_token.plaintext_token}")

    assert_response :unauthorized
    assert_includes response.headers["WWW-Authenticate"], %(error="invalid_token")
  end

  # --- backwards compatibility -----------------------------------------------

  test "long-lived API keys still authenticate MCP requests" do
    api_key = @user.api_keys.create!(name: "CI")

    post "/mcp/endpoint", params: rpc(method: "tools/list"),
         headers: MCP_HEADERS.merge("Authorization" => "Bearer #{api_key.token}")

    assert_response :success
  end

  test "the device flow still issues a token from the shared token endpoint" do
    post "/oauth/device", params: { client_id: "headless-cli" }
    assert_response :success
    device_code = response.parsed_body["device_code"]

    DeviceCode.find_by(device_code: device_code).authorize!(@user)

    post "/oauth/token", params: {
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
      device_code: device_code
    }

    assert_response :success
    assert response.parsed_body["access_token"].present?
  end

  private

  def sign_in
    post session_path, params: { email_address: @user.email_address, password: "password123" }
  end

  def register_client(**overrides)
    payload = {
      client_name: "MCP Test Client",
      redirect_uris: [ REDIRECT_URI ],
      scope: "mcp:read mcp:write"
    }.merge(overrides)

    post "/oauth/register", params: payload.to_json,
         headers: { "Content-Type" => "application/json" }

    response.parsed_body
  end

  def authorize_params(client, verifier)
    {
      client_id: client["client_id"],
      redirect_uri: REDIRECT_URI,
      response_type: "code",
      scope: "mcp:read mcp:write",
      state: "xyz-state",
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false),
      code_challenge_method: "S256",
      resource: RESOURCE
    }
  end

  def issue_token(scopes:, resource: RESOURCE)
    application = Doorkeeper::Application.create!(
      name: "Test Client #{SecureRandom.hex(4)}",
      redirect_uri: REDIRECT_URI,
      scopes: scopes,
      confidential: false
    )

    Doorkeeper::AccessToken.create!(
      application: application,
      resource_owner_id: @user.id,
      scopes: scopes,
      expires_in: 2.hours,
      resource: resource
    )
  end

  def rpc(method:, params: nil, id: 1)
    body = { jsonrpc: "2.0", id: id, method: method }
    body[:params] = params if params
    body.to_json
  end
end
