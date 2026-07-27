module Api
  module V1
    class AccountsController < Api::BaseController
      # GET /api/v1/accounts?source=wechat&id=xxx
      # GET /api/v1/accounts?source=twitter&name=xxx
      # GET /api/v1/accounts?source=rednote&id=xxx
      def index
        source = params[:source].to_s.strip.presence
        id = params[:id].to_s.strip.presence
        name = params[:name].to_s.strip.presence

        if source.blank?
          render json: { error: "source 不能为空（wechat/rednote/twitter）" }, status: :bad_request
          return
        end

        unless %w[wechat rednote twitter].include?(source.downcase)
          render json: { error: "不支持的平台: #{source}" }, status: :bad_request
          return
        end

        if id.blank? && name.blank?
          render json: { error: "至少需要提供 id 或 name 参数" }, status: :bad_request
          return
        end

        result = AccountResolver.resolve(source: source, id: id, name: name)

        if result.account
          account = result.account
          render json: {
            source: source.downcase,
            id: account.fakeid,
            name: account.nickname,
            round_head_img: account.round_head_img,
            status: result.status
          }
        else
          render json: {
            source: source.downcase,
            id: id,
            name: name,
            status: result.status,
            error: result.error
          }, status: :not_found
        end
      end
    end
  end
end
