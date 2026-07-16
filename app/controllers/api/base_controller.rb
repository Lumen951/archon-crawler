module Api
  class BaseController < ActionController::API
    before_action :authenticate_api_key

    rescue_from ActiveRecord::RecordNotFound, with: :not_found
    rescue_from ActiveRecord::RecordInvalid, with: :unprocessable_entity
    rescue_from ActionController::ParameterMissing, with: :bad_request

    private

    def authenticate_api_key
      token = request.headers["Authorization"]&.gsub(/^Bearer\s+/, "")

      if token.blank?
        render json: { error: "缺少 Authorization header" }, status: :unauthorized
        return
      end

      @current_api_key = ApiKey.find_by_token(token)

      if @current_api_key.nil?
        render json: { error: "无效的 API key" }, status: :unauthorized
        return
      end

      @current_user = @current_api_key.user
    end

    def current_user
      @current_user
    end

    def current_api_key
      @current_api_key
    end

    def not_found(exception)
      render json: { error: exception.message }, status: :not_found
    end

    def unprocessable_entity(exception)
      render json: { error: exception.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end

    def bad_request(exception)
      render json: { error: exception.message }, status: :bad_request
    end
  end
end
