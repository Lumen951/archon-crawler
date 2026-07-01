namespace :import do
  desc "Import accounts from JSON file"
  task accounts: :environment do
    import_file = Rails.root.join("wechat_accounts_import_final.json")

    unless File.exist?(import_file)
      puts "Error: #{import_file} not found"
      exit 1
    end

    result = File.open(import_file, "rb") do |file|
      Accounts::Importer.import_file(file)
    end

    result.errors.each do |error|
      puts "✗ #{error}"
    end

    puts "\n" + "=" * 50
    puts "Import completed!"
    puts "Imported: #{result.imported_count} accounts"
    puts "Skipped: #{result.skipped_count} accounts"
    puts "Invalid: #{result.invalid_count} rows"
    puts "Total: #{Account.count} accounts in database"
  end
end
