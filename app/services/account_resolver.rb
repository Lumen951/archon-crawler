class AccountResolver
  Result = Struct.new(:account, :status, :error, keyword_init: true)

  def self.resolve(source:, id: nil, name: nil)
    new.resolve(source: source, id: id, name: name)
  end

  def resolve(source:, id: nil, name: nil)
    case source.to_s.downcase
    when "wechat"
      resolve_wechat(id: id, name: name)
    when "rednote"
      resolve_rednote(id: id, name: name)
    when "twitter"
      resolve_twitter(id: id, name: name)
    else
      Result.new(account: nil, status: "error", error: "不支持的平台: #{source}")
    end
  end

  private

  def resolve_wechat(id: nil, name: nil)
    if id.present?
      account = WechatAccount.find_by(fakeid: id)
      if account
        Result.new(account: account, status: "found", error: nil)
      else
        Result.new(account: nil, status: "not_found", error: "微信帐号未找到: #{id}")
      end
    elsif name.present?
      # Search by name using WechatApiClient
      begin
        response = WechatApiClient.search_account(name)
        accounts = extract_accounts_from_search_response(response)

        if accounts.empty?
          Result.new(account: nil, status: "not_found", error: "微信帐号未找到: #{name}")
        else
          # Use the first result
          account_data = accounts.first
          account = WechatAccount.find_or_initialize_by(fakeid: account_data[:fakeid])

          if account.new_record?
            account.nickname = account_data[:nickname]
            account.round_head_img = account_data[:round_head_img]
            account.status = :active
            account.total_articles = account_data[:total_articles] || 0
            account.save!
            Result.new(account: account, status: "created", error: nil)
          else
            Result.new(account: account, status: "found", error: nil)
          end
        end
      rescue WechatApiClient::ApiError => e
        Result.new(account: nil, status: "error", error: "微信搜索失败: #{e.message}")
      rescue StandardError => e
        Result.new(account: nil, status: "error", error: "微信搜索失败: #{e.message}")
      end
    else
      Result.new(account: nil, status: "error", error: "微信帐号需要提供 id 或 name")
    end
  end

  def resolve_rednote(id: nil, name: nil)
    if name.present?
      return Result.new(account: nil, status: "error", error: "小红书不支持按名称搜索，请使用 id")
    end

    if id.present?
      # First check if account exists in database
      account = RednoteAccount.find_by(fakeid: id)
      if account
        Result.new(account: account, status: "found", error: nil)
      else
        # Validate user exists on Rednote via API
        begin
          user_data = RednoteApiClient.get_user_detail(id)

          if user_data.present? && user_data["basic_info"].present?
            # Create account from API response
            account = RednoteAccount.new(
              fakeid: id,
              nickname: user_data["basic_info"]["nickname"] || "未知用户",
              round_head_img: user_data["basic_info"]["images"],
              status: :active,
              total_articles: 0
            )
            account.save!
            Result.new(account: account, status: "created", error: nil)
          else
            Result.new(account: nil, status: "not_found", error: "小红书帐号未找到: #{id}")
          end
        rescue RednoteApiClient::ApiKeyMissingError => e
          Result.new(account: nil, status: "error", error: "小红书 API 密钥未配置: #{e.message}")
        rescue RednoteApiClient::ApiError => e
          Result.new(account: nil, status: "error", error: "小红书 API 错误: #{e.message}")
        rescue StandardError => e
          Result.new(account: nil, status: "error", error: "小红书帐号验证失败: #{e.message}")
        end
      end
    else
      Result.new(account: nil, status: "error", error: "小红书帐号需要提供 id")
    end
  end

  def resolve_twitter(id: nil, name: nil)
    if id.present?
      account = TwitterAccount.find_by(fakeid: id)
      if account
        Result.new(account: account, status: "found", error: nil)
      else
        Result.new(account: nil, status: "not_found", error: "Twitter 帐号未找到: #{id}")
      end
    elsif name.present?
      # Search by name using TwitterApiClient
      begin
        users = TwitterApiClient.lookup_user(name)

        if users.is_a?(Array) && users.first
          user = users.first
          account = TwitterAccount.find_or_initialize_by(fakeid: user["rest_id"].to_s)

          if account.new_record?
            account.nickname = user["name"] || name
            account.round_head_img = user["profile_image_url_https"]
            account.status = :active
            account.total_articles = 0
            account.save!
            Result.new(account: account, status: "created", error: nil)
          else
            Result.new(account: account, status: "found", error: nil)
          end
        else
          Result.new(account: nil, status: "not_found", error: "Twitter 帐号未找到: #{name}")
        end
      rescue TwitterApiClient::ApiError => e
        Result.new(account: nil, status: "error", error: "Twitter 搜索失败: #{e.message}")
      rescue StandardError => e
        Result.new(account: nil, status: "error", error: "Twitter 搜索失败: #{e.message}")
      end
    else
      Result.new(account: nil, status: "error", error: "Twitter 帐号需要提供 id 或 name")
    end
  end

  def extract_accounts_from_search_response(response)
    return [] unless response.is_a?(Hash)

    # Handle different response formats
    rows = if response["accounts"].is_a?(Array)
             response["accounts"]
           elsif response["list"].is_a?(Array)
             response["list"]
           elsif response.dig("data", "accounts").is_a?(Array)
             response.dig("data", "accounts")
           elsif response.dig("data", "list").is_a?(Array)
             response.dig("data", "list")
           else
             []
           end

    rows.filter_map do |row|
      next unless row.is_a?(Hash)

      {
        fakeid: row["fakeid"]&.to_s&.strip,
        nickname: (row["nickname"] || row["name"])&.to_s&.strip,
        round_head_img: (row["round_head_img"] || row["avatar"])&.to_s&.strip,
        total_articles: (row["articles"] || row["total_articles"]).to_i
      }
    end
  end
end
