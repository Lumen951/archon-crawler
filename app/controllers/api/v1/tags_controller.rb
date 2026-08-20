module Api
  module V1
    class TagsController < Api::BaseController
      # GET /api/v1/tags
      def index
        tags = Tag.ordered

        # Optional search
        if params[:q].present?
          tags = tags.search(params[:q])
        end

        render json: {
          tags: tags.map { |t| tag_json(t) }
        }
      end

      # GET /api/v1/tags/:id
      def show
        tag = Tag.find(params[:id])
        render json: { tag: tag_json(tag, detail: true) }
      end

      # POST /api/v1/tags
      def create
        tag = Tag.find_or_create_by_name(params[:name])

        if tag.persisted?
          render json: { tag: tag_json(tag) }, status: :created
        else
          render json: { error: tag.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end

      private

      def tag_json(tag, detail: false)
        json = {
          id: tag.id,
          name: tag.name,
          color: tag.color,
          description: tag.description,
          accounts_count: tag.tag_accounts_count
        }

        if detail
          json[:accounts] = tag.accounts
            .includes(:tags)
            .order(nickname: :asc)
            .limit(50)
            .map { |a|
              {
                id: a.id,
                fakeid: a.fakeid,
                nickname: a.nickname,
                platform: a.type.sub("Account", "").downcase,
                status: a.status,
                activity_level: a.activity_level.to_s
              }
            }
        end

        json
      end
    end
  end
end
