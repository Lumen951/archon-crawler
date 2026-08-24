module Oauth
  # RFC 7591 Dynamic Client Registration.
  #
  # This endpoint is unauthenticated by necessity — an MCP client has to be able
  # to register itself before any user has authorized anything. That makes it the
  # one place where an anonymous caller can write a row, so it is throttled per
  # IP and validates redirect URIs strictly.
  class RegistrationsController < ActionController::API
    REGISTRATIONS_PER_IP_PER_HOUR = 10
    MAX_REDIRECT_URIS = 10
    CONFIDENTIAL_AUTH_METHODS = %w[client_secret_basic client_secret_post].freeze

    def create
      return render_error("temporarily_unavailable", "Too many registrations from this address", :too_many_requests) if throttled?

      redirect_uris = Array(params[:redirect_uris]).map(&:to_s).reject(&:blank?)

      if redirect_uris.empty?
        return render_error("invalid_redirect_uri", "redirect_uris is required")
      end

      if redirect_uris.size > MAX_REDIRECT_URIS
        return render_error("invalid_redirect_uri", "At most #{MAX_REDIRECT_URIS} redirect URIs may be registered")
      end

      rejected = redirect_uris.reject { |uri| McpOauth.acceptable_redirect_uri?(uri) }
      if rejected.any?
        return render_error(
          "invalid_redirect_uri",
          "Redirect URIs must use https, or http on a loopback address: #{rejected.join(", ")}"
        )
      end

      application = Doorkeeper::Application.new(
        name: client_name,
        redirect_uri: redirect_uris.join("\n"),
        scopes: requested_scopes.join(" "),
        confidential: confidential?
      )

      if application.save
        count_registration!
        render json: registration_response(application), status: :created
      else
        render_error("invalid_client_metadata", application.errors.full_messages.to_sentence)
      end
    end

    private

    def registration_response(application)
      body = {
        client_id: application.uid,
        client_id_issued_at: application.created_at.to_i,
        client_name: application.name,
        redirect_uris: application.redirect_uri.split("\n"),
        grant_types: %w[authorization_code refresh_token],
        response_types: %w[code],
        scope: application.scopes.to_s,
        token_endpoint_auth_method: confidential? ? "client_secret_post" : "none"
      }

      # Public clients hold no secret; they prove possession with PKCE instead.
      if confidential?
        body[:client_secret] = application.secret
        body[:client_secret_expires_at] = 0
      end

      body
    end

    def client_name
      name = params[:client_name].presence || "MCP Client"
      name.to_s.truncate(100)
    end

    # Ignore anything outside the scopes this server actually understands rather
    # than failing registration: clients routinely ask for a broader set.
    def requested_scopes
      requested = params[:scope].to_s.split(/\s+/)
      allowed = requested & McpOauth::SCOPES
      allowed.presence || [ McpOauth::READ_SCOPE ]
    end

    def confidential?
      CONFIDENTIAL_AUTH_METHODS.include?(params[:token_endpoint_auth_method].to_s)
    end

    def throttle_key = "oauth:dcr:#{request.remote_ip}:#{Time.current.strftime("%Y%m%d%H")}"

    def throttled?
      Rails.cache.read(throttle_key).to_i >= REGISTRATIONS_PER_IP_PER_HOUR
    end

    def count_registration!
      Rails.cache.write(throttle_key, Rails.cache.read(throttle_key).to_i + 1, expires_in: 1.hour)
    end

    def render_error(error, description, status = :bad_request)
      render json: { error: error, error_description: description }, status: status
    end
  end
end
