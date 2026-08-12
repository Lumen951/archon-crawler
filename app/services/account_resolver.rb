class AccountResolver
  Result = Struct.new(:accounts, :status, :error, keyword_init: true) do
    # Convenience: first account or nil (for backward-compatible single-account usage)
    def account
      accounts&.first
    end
  end

  # ─── Search-only methods (return raw data, no DB writes) ──────────

  # Search Wechat accounts by keyword via WechatMpNativeApiClient (direct mp.weixin.qq.com access).
  # Requires prior QR code login via Admin Settings.
  # Returns [{fakeid:, nickname:, round_head_img:, total_articles:}]
  def self.search_wechat(keyword)
    response = WechatMpNativeApiClient.search_account(keyword)
    rows = extract_accounts_from_search_response(response)
    raise ArgumentError, "未搜索到匹配的帐号" if rows.empty?
    rows
  end

  # Search Rednote accounts by keyword via TikHub API.
  # Returns [{user_id:, nickname:, avatar:}]
  def self.search_rednote(keyword)
    data = TikHubApiClient.search_users(keyword: keyword)
    users = extract_rednote_users_from_search(data)
    users
  end

  # Look up a single Rednote user by profile ID via RednoteApiClient.
  # Returns {user_id:, nickname:, image:} or nil if not found.
  def self.search_rednote_by_id(user_id)
    user_data = RednoteApiClient.get_user_detail(user_id)
    return nil unless user_data.present? && user_data["basic_info"].present?

    basic = user_data["basic_info"]
    {
      user_id:  user_id,
      nickname: basic["nickname"] || "",
      image:    basic["images"] || ""
    }
  end

  # Look up a Twitter user by screen_name via TwitterApiClient.
  # Returns raw user hash(es) from the API: [{rest_id:, name:, screen_name:, ...}]
  def self.search_twitter(screen_name)
    users = TwitterApiClient.lookup_user(screen_name)
    users.is_a?(Array) ? users : []
  end

  # ─── Resolve methods (search + DB create) ────────────────────────

  # Resolve a WeChat account from an article URL via WereadApiClient.
  # Returns a Result with the found or created WechatAccount.
  def self.resolve_wechat_by_url(url)
    url = url.to_s.strip
    raise ArgumentError, "请输入微信公众号文章链接" if url.blank?
    raise ArgumentError, "请输入有效的微信公众号文章链接（包含 mp.weixin.qq.com）" unless url.include?("mp.weixin.qq.com")

    mp_info_list = WereadApiClient.get_mp_info(url)
    unless mp_info_list.is_a?(Array) && mp_info_list.any?
      return Result.new(accounts: [], status: "error", error: "未能从该链接解析到公众号信息，请确认链接有效")
    end

    mp_info = mp_info_list.first
    mp_id = mp_info["id"]
    unless mp_id.present?
      return Result.new(accounts: [], status: "error", error: "未能从该链接解析到 mpId")
    end

    # Check if account already exists (by fakeid or weread_mp_id metadata)
    account = WechatAccount.find_by(fakeid: mp_id) ||
              WechatAccount.where("metadata->>'weread_mp_id' = ?", mp_id).first

    if account
      # Update weread_mp_id if not set
      if account.metadata&.dig("weread_mp_id").blank?
        account.metadata ||= {}
        account.metadata["weread_mp_id"] = mp_id
        account.save!
      end
      Result.new(accounts: [account], status: "found", error: nil)
    else
      account = WechatAccount.create!(
        fakeid: mp_id,
        nickname: mp_info["name"].presence || "未知公众号",
        round_head_img: mp_info["cover"].presence || "",
        status: :active,
        metadata: {
          "weread_mp_id" => mp_id,
          "weread_intro" => mp_info["intro"],
          "weread_update_time" => mp_info["updateTime"]
        }
      )
      Result.new(accounts: [account], status: "created", error: nil)
    end
  rescue WereadApiClient::ApiError => e
    Result.new(accounts: [], status: "error", error: "解析失败：#{e.message}")
  rescue ActiveRecord::RecordInvalid => e
    Result.new(accounts: [], status: "error", error: "创建帐号失败：#{e.message}")
  end

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
      Result.new(accounts: [], status: "error", error: "不支持的平台: #{source}")
    end
  end

  private

  def resolve_wechat(id: nil, name: nil)
    if id.present?
      account = WechatAccount.find_by(fakeid: id)
      if account
        Result.new(accounts: [ account ], status: "found", error: nil)
      else
        Result.new(accounts: [], status: "not_found", error: "微信帐号未找到: #{id}")
      end
    elsif name.present?
      # Check DB first by nickname
      accounts = WechatAccount.where(nickname: name).to_a
      return Result.new(accounts: accounts, status: "found", error: nil) if accounts.any?

      # Search via API and create
      begin
        search_results = self.class.search_wechat(name)
        resolved = create_wechat_accounts(search_results)
        Result.new(accounts: resolved, status: "found", error: nil)
      rescue ArgumentError
        Result.new(accounts: [], status: "not_found", error: "微信帐号未找到: #{name}")
      rescue WechatMpNativeApiClient::ApiError => e
        Result.new(accounts: [], status: "error", error: "微信搜索失败: #{e.message}")
      rescue StandardError => e
        Result.new(accounts: [], status: "error", error: "微信搜索失败: #{e.message}")
      end
    else
      Result.new(accounts: [], status: "error", error: "微信帐号需要提供 id 或 name")
    end
  end

  def resolve_rednote(id: nil, name: nil)
    if id.present?
      resolve_rednote_by_id(id)
    elsif name.present?
      resolve_rednote_by_name(name)
    else
      Result.new(accounts: [], status: "error", error: "小红书帐号需要提供 id 或 name")
    end
  end

  def resolve_rednote_by_id(id)
    account = RednoteAccount.find_by(fakeid: id)
    return Result.new(accounts: [ account ], status: "found", error: nil) if account

    begin
      user_info = self.class.search_rednote_by_id(id)
      if user_info.present?
        account = RednoteAccount.create!(
          fakeid: id,
          nickname: user_info[:nickname].presence || "未知用户",
          round_head_img: user_info[:image],
          status: :active,
          total_articles: 0
        )
        Result.new(accounts: [ account ], status: "created", error: nil)
      else
        Result.new(accounts: [], status: "not_found", error: "小红书帐号未找到: #{id}")
      end
    rescue RednoteApiClient::ApiKeyMissingError => e
      Result.new(accounts: [], status: "error", error: "小红书 API 密钥未配置: #{e.message}")
    rescue RednoteApiClient::ApiError => e
      Result.new(accounts: [], status: "error", error: "小红书 API 错误: #{e.message}")
    rescue StandardError => e
      Result.new(accounts: [], status: "error", error: "小红书帐号验证失败: #{e.message}")
    end
  end

  def resolve_rednote_by_name(name)
    # Check DB first by nickname
    accounts = RednoteAccount.where(nickname: name).to_a
    return Result.new(accounts: accounts, status: "found", error: nil) if accounts.any?

    begin
      users = self.class.search_rednote(name)
      if users.empty?
        Result.new(accounts: [], status: "not_found", error: "小红书帐号未找到: #{name}")
      else
        resolved = create_rednote_accounts(users)
        Result.new(accounts: resolved, status: "found", error: nil)
      end
    rescue TikHubApiClient::ApiKeyMissingError => e
      Result.new(accounts: [], status: "error", error: "TikHub API 密钥未配置: #{e.message}")
    rescue TikHubApiClient::ApiError => e
      Result.new(accounts: [], status: "error", error: "TikHub 搜索失败: #{e.message}")
    rescue StandardError => e
      Result.new(accounts: [], status: "error", error: "小红书搜索失败: #{e.message}")
    end
  end

  def resolve_twitter(id: nil, name: nil)
    if id.present?
      account = TwitterAccount.find_by(fakeid: id)
      if account
        Result.new(accounts: [ account ], status: "found", error: nil)
      else
        Result.new(accounts: [], status: "not_found", error: "Twitter 帐号未找到: #{id}")
      end
    elsif name.present?
      screen_name = name.strip.delete_prefix("@").downcase

      # Check DB first by twitter_screen_name
      account = TwitterAccount.find_by(twitter_screen_name: screen_name)
      return Result.new(accounts: [ account ], status: "found", error: nil) if account

      begin
        users = self.class.search_twitter(name)
        if users.any?
          resolved = create_twitter_accounts(users, fallback_screen_name: screen_name)
          Result.new(accounts: resolved, status: "found", error: nil)
        else
          Result.new(accounts: [], status: "not_found", error: "Twitter 帐号未找到: #{name}")
        end
      rescue TwitterApiClient::ApiError => e
        Result.new(accounts: [], status: "error", error: "Twitter 搜索失败: #{e.message}")
      rescue StandardError => e
        Result.new(accounts: [], status: "error", error: "Twitter 搜索失败: #{e.message}")
      end
    else
      Result.new(accounts: [], status: "error", error: "Twitter 帐号需要提供 id 或 name")
    end
  end

  # ─── Account creation helpers ─────────────────────────────────────

  def create_wechat_accounts(search_results)
    search_results.map do |data|
      account = WechatAccount.find_or_initialize_by(fakeid: data[:fakeid])
      if account.new_record?
        account.nickname = data[:nickname]
        account.round_head_img = data[:round_head_img]
        account.status = :active
        account.total_articles = data[:total_articles] || 0
        account.save!
      end
      account
    end
  end

  def create_rednote_accounts(users)
    users.map do |user_data|
      account = RednoteAccount.find_or_initialize_by(fakeid: user_data[:user_id])
      if account.new_record?
        account.nickname = user_data[:nickname]
        account.round_head_img = user_data[:avatar]
        account.status = :active
        account.total_articles = 0
        account.save!
      end
      account
    end
  end

  def create_twitter_accounts(users, fallback_screen_name: nil)
    users.map do |user|
      account = TwitterAccount.find_or_initialize_by(fakeid: user["rest_id"].to_s)
      if account.new_record?
        account.nickname = user["name"]
        account.twitter_screen_name = user["screen_name"]&.downcase || fallback_screen_name
        account.round_head_img = user["profile_image_url_https"]
        account.status = :active
        account.total_articles = 0
        account.save!
      elsif account.twitter_screen_name.blank?
        account.update!(twitter_screen_name: fallback_screen_name)
      end
      account
    end
  end

  # ─── Response parsing (shared by search & resolve) ────────────────

  def self.extract_accounts_from_search_response(response)
    return [] unless response.is_a?(Hash)

    # Check for API error response
    if response["code"].present? && response["code"].to_i != 0
      message = response["message"].presence || response["msg"].presence || "搜索帐号接口返回错误"
      raise ArgumentError, message
    end

    rows = if response["accounts"].is_a?(Array)
             response["accounts"]
           elsif response["list"].is_a?(Array)
             response["list"]
           elsif response["data"].is_a?(Array)
             response["data"]
           elsif response.dig("data", "accounts").is_a?(Array)
             response.dig("data", "accounts")
           elsif response.dig("data", "list").is_a?(Array)
             response.dig("data", "list")
           elsif response.dig("result", "accounts").is_a?(Array)
             response.dig("result", "accounts")
           elsif response.dig("result", "list").is_a?(Array)
             response.dig("result", "list")
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

  # Extract user list from TikHub search_users response.
  # Response format: { "success" => true, "code" => 0, "data" => { "users" => [...] } }
  # Each user: { "id" => "...", "name" => "...", "image" => "...", "red_id" => "...", ... }
  def self.extract_rednote_users_from_search(data)
    return [] unless data.is_a?(Hash)

    users = data.dig("data", "users") || []
    return [] unless users.is_a?(Array)

    users.filter_map do |user|
      next unless user.is_a?(Hash)

      user_id = user["id"]
      next unless user_id.present?

      {
        user_id: user_id.to_s.strip,
        nickname: user["name"].to_s.strip,
        avatar: user["image"].to_s.strip
      }
    end
  end
end
