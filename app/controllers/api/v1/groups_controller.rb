module Api
  module V1
    class GroupsController < Api::BaseController
      def create
        ref_key = params[:ref_key].to_s.strip
        accounts_params = params[:accounts] || []

        # Validate ref_key
        if ref_key.blank?
          render json: { error: "ref_key 不能为空" }, status: :unprocessable_entity
          return
        end

        unless ref_key.match?(/\A[a-zA-Z0-9_-]+\z/)
          render json: { error: "ref_key 只能包含字母、数字、下划线和连字符" }, status: :unprocessable_entity
          return
        end

        # Check uniqueness for current user
        if current_user.groups.exists?(ref_key: ref_key)
          render json: { error: "该用户已存在相同的 ref_key: #{ref_key}" }, status: :unprocessable_entity
          return
        end

        # Validate and resolve accounts
        resolved_accounts = []
        errors = []

        accounts_params.each_with_index do |account_param, index|
          source = account_param[:source].to_s.strip
          id = account_param[:id].to_s.strip.presence
          name = account_param[:name].to_s.strip.presence

          if source.blank?
            errors << { index: index, error: "source 不能为空" }
            next
          end

          result = AccountResolver.resolve(source: source, id: id, name: name)

          if result.account
            resolved_accounts << {
              account: result.account,
              source: source,
              status: result.status
            }
          else
            errors << {
              index: index,
              source: source,
              id: id,
              name: name,
              error: result.error
            }
          end
        end

        # Create group with valid accounts
        group = current_user.groups.new(ref_key: ref_key)

        ActiveRecord::Base.transaction do
          group.save!

          resolved_accounts.each do |resolved|
            group.group_accounts.create!(account: resolved[:account])
          end
        end

        render json: {
          group: {
            id: group.id,
            ref_key: group.ref_key,
            user_id: group.user_id,
            created_at: group.created_at
          },
          accounts: resolved_accounts.map { |r|
            {
              source: r[:source],
              fakeid: r[:account].fakeid,
              nickname: r[:account].nickname,
              status: r[:status]
            }
          },
          errors: errors
        }, status: :created

      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
      rescue StandardError => e
        render json: { error: "创建分组失败: #{e.message}" }, status: :internal_server_error
      end

      def show
        group = current_user.groups.find_by!(ref_key: params[:id])

        render json: {
          group: {
            id: group.id,
            ref_key: group.ref_key,
            user_id: group.user_id,
            created_at: group.created_at
          },
          accounts: group.accounts.map { |a|
            {
              source: a.type.sub("Account", "").downcase,
              fakeid: a.fakeid,
              nickname: a.nickname
            }
          }
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "分组未找到: #{params[:id]}" }, status: :not_found
      end

      def index
        groups = current_user.groups.includes(:accounts)

        render json: {
          groups: groups.map { |group|
            {
              id: group.id,
              ref_key: group.ref_key,
              user_id: group.user_id,
              created_at: group.created_at,
              accounts_count: group.accounts.count
            }
          }
        }
      end

      def update
        group = current_user.groups.find_by!(ref_key: params[:id])
        accounts_params = params[:accounts] || []

        # Resolve new accounts
        resolved_accounts = []
        errors = []

        accounts_params.each_with_index do |account_param, index|
          source = account_param[:source].to_s.strip
          id = account_param[:id].to_s.strip.presence
          name = account_param[:name].to_s.strip.presence

          if source.blank?
            errors << { index: index, error: "source 不能为空" }
            next
          end

          result = AccountResolver.resolve(source: source, id: id, name: name)

          if result.account
            resolved_accounts << result.account
          else
            errors << {
              index: index,
              source: source,
              id: id,
              name: name,
              error: result.error
            }
          end
        end

        # Update group accounts
        ActiveRecord::Base.transaction do
          group.group_accounts.destroy_all
          resolved_accounts.each do |account|
            group.group_accounts.create!(account: account)
          end
        end

        render json: {
          group: {
            id: group.id,
            ref_key: group.ref_key,
            user_id: group.user_id,
            created_at: group.created_at
          },
          accounts: resolved_accounts.map { |a|
            {
              source: a.type.sub("Account", "").downcase,
              fakeid: a.fakeid,
              nickname: a.nickname
            }
          },
          errors: errors
        }

      rescue ActiveRecord::RecordNotFound
        render json: { error: "分组未找到: #{params[:id]}" }, status: :not_found
      rescue StandardError => e
        render json: { error: "更新分组失败: #{e.message}" }, status: :internal_server_error
      end

      def destroy
        group = current_user.groups.find_by!(ref_key: params[:id])
        group.destroy!

        render json: { message: "分组已删除" }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "分组未找到: #{params[:id]}" }, status: :not_found
      end
    end
  end
end
