namespace :crawl do
  desc "Clean up old crawl logs based on retention days setting"
  task cleanup_logs: :environment do
    retention_days = Option[:crawler_log_retention_days].to_i
    deleted_count = CrawlLog.cleanup_old_logs
    puts "Cleaned up #{deleted_count} log entries older than #{retention_days} days"
  end
end
