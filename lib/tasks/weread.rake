require "net/http"
require "json"
require "cgi"

namespace :weread do
  desc "发起微信读书登录 (获取二维码，轮询扫码结果)"
  task login: :environment do
    puts "=" * 60
    puts "WeRead 微信读书账号登录"
    puts "转发服务: #{Option.weread_platform_url}"
    puts "=" * 60

    begin
      # Step 1: 获取登录二维码
      result = WereadApiClient.create_login_url
      uuid = result["uuid"]
      scan_url = result["scanUrl"]

      puts "\n二维码获取成功!"
      puts "  二维码 URL: #{scan_url}"
      puts "  会话 ID: #{uuid}"
      puts "\n请用微信扫描二维码，或在浏览器打开上述 URL 扫描"
      puts "(qrencode 可用时，二维码会显示在终端中)"

      # 尝试显示终端二维码
      if system("which qrencode > /dev/null 2>&1")
        system("qrencode -t ANSIUTF8 '#{scan_url}'")
      else
        puts "提示: 安装 qrencode 可在终端直接显示二维码: brew install qrencode"
      end

      # Step 2: 轮询登录结果
      puts "\n等待扫码..."
      max_attempts = 24 # 120s / 5s
      success = false

      max_attempts.times do |i|
        sleep 5
        begin
          data = WereadApiClient.get_login_result(uuid)

          if data["vid"] && data["token"]
            vid = data["vid"].to_s
            token = data["token"].to_s
            username = data["username"] || "wechat_user"

            # 保存到 Option
            accounts = Option.weread_accounts
            existing = accounts.find { |a| a["vid"].to_s == vid }

            if existing
              existing["token"] = token
              existing["name"] = username
              existing["status"] = 1
            else
              accounts << {
                "vid" => vid,
                "token" => token,
                "name" => username,
                "status" => 1
              }
            end

            Option.weread_accounts = accounts

            # 从黑名单中移除
            WereadApiClient.remove_blocked_account(vid)

            puts "\n✅ 登录成功!"
            puts "  账号 ID: #{vid}"
            puts "  用户名: #{username}"
            success = true
            break
          elsif data["message"].present?
            puts "  [#{i + 1}/#{max_attempts}] #{data['message']}"
          end
        rescue WereadApiClient::ApiError => e
          puts "  [#{i + 1}/#{max_attempts}] 轮询错误: #{e.message}"
        end
      end

      unless success
        puts "\n❌ 登录超时，请重试"
      end
    rescue WereadApiClient::ApiError => e
      puts "\n❌ 登录失败: #{e.message}"
    end
  end

  desc "列出所有 WeRead 账号"
  task accounts_list: :environment do
    accounts = Option.weread_accounts
    blocked = Option.weread_blocked_accounts
    date_key = WereadApiClient.today_shanghai
    today_blocked = blocked[date_key] || []

    if accounts.empty?
      puts "暂无 WeRead 账号"
      return
    end

    puts "=" * 80
    puts "WeRead 微信读书账号列表"
    puts "=" * 80
    puts "%-5s %-15s %-20s %-10s %s" % ["#", "VID", "用户名", "状态", "备注"]
    puts "-" * 80

    accounts.each_with_index do |a, i|
      vid = a["vid"].to_s
      status = case a["status"].to_i
               when 0 then "⛔ 失效"
               when 1 then "✅ 启用"
               when 2 then "⏸️ 禁用"
               else "❓ 未知"
               end

      notes = []
      notes << "今日黑名单" if today_blocked.include?(vid)
      note_str = notes.empty? ? "" : notes.join(", ")

      puts "%-5d %-15s %-20s %-10s %s" % [i + 1, vid[0..14], (a["name"] || "")[0..19], status, note_str]
    end
    puts "-" * 80
    puts "共 #{accounts.size} 个账号 | 今日黑名单: #{today_blocked.size} 个"
    puts "=" * 80
  end

  desc "手动添加 WeRead 账号 (VID=xxx TOKEN=xxx NAME=xxx)"
  task add_account: :environment do
    vid = ENV["VID"].to_s.strip
    token = ENV["TOKEN"].to_s.strip
    name = ENV["NAME"].to_s.strip.presence || "manual_#{vid[0..7]}"

    if vid.empty? || token.empty?
      puts "用法: rails weread:add_account VID=<vid> TOKEN=<token> [NAME=<name>]"
      exit 1
    end

    accounts = Option.weread_accounts
    existing = accounts.find { |a| a["vid"].to_s == vid }

    if existing
      existing["token"] = token
      existing["name"] = name
      existing["status"] = 1
      puts "已更新账号: #{vid}"
    else
      accounts << { "vid" => vid, "token" => token, "name" => name, "status" => 1 }
      puts "已添加账号: #{vid}"
    end

    Option.weread_accounts = accounts
    WereadApiClient.remove_blocked_account(vid)
  end

  desc "移除 WeRead 账号 (VID=xxx)"
  task remove_account: :environment do
    vid = ENV["VID"].to_s.strip
    if vid.empty?
      puts "用法: rails weread:remove_account VID=<vid>"
      exit 1
    end

    accounts = Option.weread_accounts
    before = accounts.size
    accounts.reject! { |a| a["vid"].to_s == vid }

    if accounts.size < before
      Option.weread_accounts = accounts
      WereadApiClient.remove_blocked_account(vid)
      puts "已移除账号: #{vid}"
    else
      puts "未找到账号: #{vid}"
    end
  end

  desc "启用 WeRead 账号 (VID=xxx)"
  task enable_account: :environment do
    vid = ENV["VID"].to_s.strip
    if vid.empty?
      puts "用法: rails weread:enable_account VID=<vid>"
      exit 1
    end

    accounts = Option.weread_accounts
    match = accounts.find { |a| a["vid"].to_s == vid }
    if match
      match["status"] = 1
      Option.weread_accounts = accounts
      WereadApiClient.remove_blocked_account(vid)
      puts "已启用账号: #{vid}"
    else
      puts "未找到账号: #{vid}"
    end
  end

  desc "禁用 WeRead 账号 (VID=xxx)"
  task disable_account: :environment do
    vid = ENV["VID"].to_s.strip
    if vid.empty?
      puts "用法: rails weread:disable_account VID=<vid>"
      exit 1
    end

    accounts = Option.weread_accounts
    match = accounts.find { |a| a["vid"].to_s == vid }
    if match
      match["status"] = 2
      Option.weread_accounts = accounts
      puts "已禁用账号: #{vid}"
    else
      puts "未找到账号: #{vid}"
    end
  end

  desc "通过微信文章 URL 查询公众号信息，并可选择创建 WechatAccount (URL=xxx)"
  task lookup_mp: :environment do
    url = ENV["URL"].to_s.strip
    if url.empty?
      puts "用法: rails weread:lookup_mp URL='https://mp.weixin.qq.com/s/...'"
      exit 1
    end

    puts "查询公众号信息..."
    puts "URL: #{url}"

    begin
      result = WereadApiClient.get_mp_info(url)
      if result.is_a?(Array) && result.any?
        mp = result.first
        mp_id = mp["id"]
        mp_name = mp["name"]
        mp_intro = (mp["intro"] || "")[0..100]
        mp_cover = mp["cover"]
        mp_update_time = Time.at(mp["updateTime"].to_i) if mp["updateTime"]

        puts "-" * 60
        puts "mpId:    #{mp_id}"
        puts "名称:    #{mp_name}"
        puts "简介:    #{mp_intro}"
        puts "封面:    #{mp_cover}"
        puts "更新时间: #{mp_update_time}"
        puts "-" * 60

        # Check if already exists in WechatAccount
        existing = WechatAccount.find_by(fakeid: mp_id)
        unless existing
          # Also check by metadata.weread_mp_id in case fakeid differs
          existing = WechatAccount.where("metadata->>'weread_mp_id' = ?", mp_id).first
        end

        if existing
          puts "\n✅ 该公众号已存在于爬取列表中:"
          puts "   ID: #{existing.id}"
          puts "   昵称: #{existing.nickname}"
          puts "   fakeid: #{existing.fakeid}"
          puts "   状态: #{existing.status}"
          puts "   链接: /accounts/#{existing.id}"
        else
          puts "\n该公众号尚未在爬取列表中。"
          print "是否创建 WechatAccount? [y/N]: "
          answer = $stdin.gets.to_s.strip.downcase
          if answer == "y" || answer == "yes"
            account = WechatAccount.create!(
              fakeid: mp_id,
              nickname: mp_name,
              round_head_img: mp_cover,
              status: :active,
              metadata: {
                "weread_mp_id" => mp_id,
                "weread_intro" => mp_intro,
                "weread_update_time" => mp["updateTime"]
              }
            )
            puts "\n✅ WechatAccount 创建成功!"
            puts "   ID: #{account.id}"
            puts "   fakeid: #{account.fakeid}"
            puts "   昵称: #{account.nickname}"
            puts "   链接: /accounts/#{account.id}"
          else
            puts "\n跳过创建。可通过以下方式手动添加:"
            puts "  rails runner \"WechatAccount.create!(fakeid: '#{mp_id}', nickname: '#{mp_name}', metadata: { weread_mp_id: '#{mp_id}' })\""
          end
        end
      else
        puts "未查询到公众号信息"
      end
    rescue WereadApiClient::ApiError => e
      puts "查询失败: #{e.message}"
    rescue ActiveRecord::RecordInvalid => e
      puts "创建失败: #{e.message}"
    end
  end

  desc "清除当日黑名单"
  task clear_blocked: :environment do
    Option.weread_blocked_accounts = {}
    puts "已清除 WeRead 黑名单"
  end

  desc "显示 WeRead 配置状态"
  task status: :environment do
    puts "=" * 60
    puts "WeRead 配置状态"
    puts "=" * 60
    puts "转发服务: #{Option.weread_platform_url}"
    puts "可用账号: #{Option.weread_accounts_valid? ? '✅ 有' : '❌ 无'}"
    puts "账号数量: #{Option.weread_accounts.size}"
    puts "启用账号: #{Option.weread_accounts.count { |a| a['status'].to_i == 1 }}"

    blocked = Option.weread_blocked_accounts
    date_key = WereadApiClient.today_shanghai
    today_blocked = blocked[date_key] || []
    puts "今日黑名单: #{today_blocked.size} 个 #{today_blocked.any? ? today_blocked.join(', ') : ''}"
    puts "=" * 60
  end
end
