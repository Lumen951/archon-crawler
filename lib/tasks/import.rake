namespace :import do
  desc "Import accounts from JSON file"
  task accounts: :environment do
    json_file = Rails.root.join("wechat_accounts_import_final.json")

    unless File.exist?(json_file)
      puts "Error: #{json_file} not found"
      exit 1
    end

    json = JSON.parse(File.read(json_file))

    imported = 0
    skipped = 0

    json["accounts"].each do |data|
      account = Account.find_or_initialize_by(fakeid: data["fakeid"])

      if account.new_record?
        account.nickname = data["nickname"]
        account.round_head_img = data["round_head_img"]
        account.status = :active
        account.total_articles = data["articles"] || 0
        account.save!
        imported += 1
        puts "✓ Imported: #{account.nickname} (#{account.fakeid})"
      else
        skipped += 1
        puts "- Skipped (already exists): #{account.nickname}"
      end
    end

    puts "\n" + "=" * 50
    puts "Import completed!"
    puts "Imported: #{imported} accounts"
    puts "Skipped: #{skipped} accounts"
    puts "Total: #{Account.count} accounts in database"
  end
end
