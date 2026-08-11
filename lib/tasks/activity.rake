namespace :crawl do
  desc "Refresh all account activity counters (articles_count, last_7/30_days, activity_score)"
  task refresh_activity_counters: :environment do
    total = Account.count
    puts "Refreshing activity counters for #{total} accounts..."
    processed = 0

    Account.find_each do |account|
      account.refresh_activity_counters!
      processed += 1
      print "\r  #{processed}/#{total}" if processed % 10 == 0
    end

    puts "\r  #{processed}/#{total} done."
    puts "All activity counters refreshed."
  end

  desc "Detect and report dormant accounts (active but no articles in N days)"
  task :detect_dormant, [:days, :disable] => :environment do |t, args|
    days = (args[:days] || 90).to_i
    disable = args[:disable] == "true"
    cutoff = days.days.ago

    scope = Account.active
      .where("total_articles > 0")
      .where("last_published_at < ? OR last_published_at IS NULL", cutoff)
      .order(:last_published_at)

    puts "=== Dormant Accounts (active, no articles in #{days} days) ==="
    puts "Count: #{scope.count}"
    puts ""
    printf "%-8s %-30s %-16s %s\n", "ID", "Nickname", "Platform", "Last Published"
    puts "-" * 80

    scope.find_each do |a|
      last = a.last_published_at ? "#{(Time.current - a.last_published_at).to_i / 86400}d ago" : "never"
      printf "%-8d %-30s %-16s %s\n", a.id, a.nickname.truncate(30), a.platform_name, last
    end

    if disable
      puts ""
      count = scope.update_all(status: :inactive, updated_at: Time.current)
      puts "Disabled #{count} dormant accounts."
    else
      puts ""
      puts "Run with DISABLE=true to disable these accounts:"
      puts "  rails 'crawl:detect_dormant[90,true]'"
    end
  end
end
