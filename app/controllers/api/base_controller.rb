module Api
  class BaseController < ActionController::API
    DEFAULT_PER_PAGE = 25
    MAX_PER_PAGE = 100

    before_action :authenticate_api_key

    rescue_from ActiveRecord::RecordNotFound, with: :not_found
    rescue_from ActiveRecord::RecordInvalid, with: :unprocessable_entity
    rescue_from ActionController::ParameterMissing, with: :bad_request

    private

    # Page/per_page as documented by the OpenAPI spec: page >= 1, per_page in
    # 1..100 defaulting to 25. Note the lower bound is 1, not 25 — an earlier
    # `[[params[:per_page].to_i, 25].max, 100].min` collapsed "default" into
    # "minimum", so any per_page under 25 was silently raised to 25.
    def pagination_params
      per_page = params[:per_page].presence&.to_i
      per_page = DEFAULT_PER_PAGE if per_page.nil? || per_page < 1
      per_page = MAX_PER_PAGE if per_page > MAX_PER_PAGE

      page = params[:page].presence&.to_i
      page = 1 if page.nil? || page < 1

      [ page, per_page ]
    end

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
