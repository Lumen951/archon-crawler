# Shared constants and helpers for the MCP OAuth 2.1 surface.
#
# The MCP authorization spec (2026-07-28) makes the MCP server an OAuth 2.1
# *resource server*; Doorkeeper plays the authorization server next to it. This
# module holds the few values both halves need to agree on.
#
# NOTE: the scope strings are also spelled out literally in
# config/initializers/doorkeeper.rb — an initializer must not reference an
# autoloaded constant at boot. test/services/mcp_oauth_test.rb guards the two
# definitions against drifting apart.
module McpOauth
  READ_SCOPE  = "mcp:read"
  WRITE_SCOPE = "mcp:write"
  SCOPES      = [ READ_SCOPE, WRITE_SCOPE ].freeze

  # Shown on the consent screen, so the user sees what they are handing over.
  SCOPE_DESCRIPTIONS = {
    READ_SCOPE  => "查看账号、文章、标签和活跃度统计",
    WRITE_SCOPE => "修改账号状态与标签、发起微信读书扫码登录"
  }.freeze

  # Tools that change state. Calling one of these requires WRITE_SCOPE; every
  # other tool is reachable with READ_SCOPE alone.
  WRITE_TOOLS = %w[
    update_accounts
    batch_update_accounts_by_filter
    weread_login_start
    weread_login_status
  ].freeze

  MCP_PATH = "/mcp/endpoint".freeze

  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze

  def self.write_tool?(tool_name) = WRITE_TOOLS.include?(tool_name)

  # RFC 8707 canonical resource identifier: absolute URI of the MCP endpoint,
  # no fragment, no trailing slash.
  def self.resource_identifier(base_url) = "#{base_url.chomp("/")}#{MCP_PATH}"

  # RFC 9728 §3.1 permits the metadata document either at the host root or with
  # the resource's path inserted after the well-known segment. We serve both;
  # this is the path-inserted form we advertise, since it stays unambiguous if
  # the host ever serves a second protected resource.
  def self.protected_resource_metadata_url(base_url)
    "#{base_url.chomp("/")}/.well-known/oauth-protected-resource#{MCP_PATH}"
  end

  # The WWW-Authenticate challenge that bootstraps the whole discovery chain.
  # Without this header an MCP client has no way to learn the server speaks
  # OAuth at all — it just sees a 401 and reports a connection failure.
  def self.challenge(base_url, error: nil, error_description: nil, scope: SCOPES.join(" "))
    parts = []
    # RFC 6750 §3 scopes error_description to responses that carry an error code,
    # so a bare "please authenticate" challenge stays free of both.
    if error.present?
      parts << %(error="#{error}")
      parts << %(error_description="#{error_description}") if error_description.present?
    end
    parts << %(resource_metadata="#{protected_resource_metadata_url(base_url)}")
    parts << %(scope="#{scope}") if scope.present?
    "Bearer #{parts.join(", ")}"
  end

  # True when +value+ names this MCP endpoint. The spec asks servers to accept
  # uppercase scheme/host for robustness, so compare on a normalized form rather
  # than by string equality.
  def self.matches_resource?(value, base_url)
    normalized = normalize_uri(value)
    !normalized.nil? && normalized == normalize_uri(resource_identifier(base_url))
  end

  # Lowercase scheme and host, drop a default port, drop any fragment, drop a
  # trailing slash. Returns nil for anything that is not an absolute URI.
  def self.normalize_uri(value)
    uri = URI.parse(value.to_s)
    return nil if uri.scheme.blank? || uri.host.blank?

    port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
    "#{uri.scheme.downcase}://#{uri.host.downcase}#{port}#{uri.path.to_s.chomp("/")}"
  rescue URI::InvalidURIError
    nil
  end

  # OAuth 2.1 permits plain http only for loopback redirects, which is exactly
  # what a locally-running MCP client needs.
  def self.acceptable_redirect_uri?(value)
    uri = URI.parse(value.to_s)
    case uri.scheme
    when "https" then uri.host.present?
    when "http"  then LOOPBACK_HOSTS.include?(uri.host)
    else false
    end
  rescue URI::InvalidURIError
    false
  end
end
