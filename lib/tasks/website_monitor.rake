namespace :website_monitor do
  desc "Import the reviewed robot company website rules (idempotent)"
  task import_robots: :environment do
    puts Website::Importer.import_robot_websites.to_json
  end

  desc "Check one website account by ID, domain or URL (crawls via CrawlTask)"
  task :check, [ :url_or_id ] => :environment do |_task, args|
    value = args.fetch(:url_or_id)
    account =
      if value.match?(/\A\d+\z/)
        WebsiteAccount.find(value)
      else
        host = URI.parse(value.match?(%r{\Ahttps?://}i) ? value : "https://#{value}").host.to_s
        fakeid = host.sub(/\Awww\./, "")
        WebsiteAccount.find_by!(fakeid: fakeid)
      end
    task = account.crawl!
    puts "已创建抓取任务 ##{task.id}（#{account.nickname}）"
  end

  desc "Fetch a URL without persisting monitor data"
  task :probe, [ :url ] => :environment do |_task, args|
    result = WebsiteCrawler::Fetcher.new.fetch(args.fetch(:url))
    puts({ url: result.url, status: result.status, kind: result.kind, error: result.error }.to_json)
  end
end
