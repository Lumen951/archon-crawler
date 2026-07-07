class Oauth2Client
  include Rails.application.routes.url_helpers
  class OAuthError < StandardError; end
  attr_reader :client, :provider, :credentials, :access_token

  PROVIDERS = [:mp].freeze

  def initialize(provider:, url_options:, credentials: nil)
    @credentials = credentials || get_credentials(provider)
    raise "Credentials for #{provider} is not configured" unless @credentials.present?

    url_options => { host:, port:, protocol: }

    @default_url_options = { provider:, host:, protocol: }
    @default_url_options.merge!(port:) unless [80, 443].include?(port)
    @provider = provider.to_sym

    client_id, client_secret = @credentials.fetch_values(:client_id, :client_secret)
    @client = case @provider
              when :mp
                mp_site = @credentials[:site] || raise("MP_SITE must be set for mp oauth provider")
                OAuth2::Client.new(
                  client_id,
                  client_secret,
                  site: mp_site,
                  redirect_uri: oauth_callback_url(@default_url_options)
                )
              else
                raise "Unknown oauth provider #{provider}"
              end
  end

  def user_hash(code)
    raw_info = user_raw_info(code)
    case provider
    when :mp
      raw_info.slice(:name, :email, :phone).merge(mp_id: raw_info[:id])
    else
      raw_info.slice(:name, :email)
    end
  end

  def user_raw_info(code)
    @access_token ||= client.auth_code.get_token(code)
    raw_info = case provider
               when :mp
                 access_token.get('/open_api/v1/user/me').parsed
               else
                 raise "Unknown provider #{provider}"
               end

    Rails.logger.debug "Oauth2Client user_raw_info: #{raw_info}"
    raw_info.symbolize_keys
  end

  def authorize_url(options = {})
    client.auth_code.authorize_url(options)
  end

  private

  def get_credentials(provider)
    case provider.to_sym
    when :mp
      client_id = Rails.application.credentials.dig(:mp_oauth, :client_id)
      client_secret = Rails.application.credentials.dig(:mp_oauth, :client_secret)

      return unless client_id && client_secret

      {
        client_id:,
        client_secret:,
        site: ENV["MP_SITE"] || "https://build.miracleplus.com"
      }
    else
      nil
    end
  end
end
