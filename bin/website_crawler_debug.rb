#!/usr/bin/env ruby
# frozen_string_literal: true

# Verbose CLI runner for WebsiteCrawler. Runs the real production pipeline
# (WebsiteCrawler.crawl_account) against one WebsiteAccount, then prints a
# numbered, step-by-step transcript of what happened — including the raw
# listing items (title/url/date_text) extracted from each monitor page and
# how each date_text parses into published_at — so pipeline issues (e.g.
# published_at always defaulting to today because no date was extracted) are
# visible without digging through the crawl_logs table by hand.
#
# Usage:
#   bin/website_crawler_debug.rb deepseek.com
#   bin/website_crawler_debug.rb https://www.deepseek.com --max-pages 2 --max-items 3
#
# --max-pages also caps account.max_pages for this account (so discovery /
# the real crawl only touches that many pages) — useful to keep debug runs
# fast. --max-items only limits how many listing items get detailed output.

require_relative "../config/environment"
require "optparse"

options = { max_pages: nil, max_items: 5 }
OptionParser.new do |opts|
  opts.banner = "Usage: bin/website_crawler_debug.rb <domain_or_url> [options]"
  opts.on("--max-pages N", Integer, "Cap account.max_pages for this run") { |v| options[:max_pages] = v }
  opts.on("--max-items N", Integer, "Limit listing items shown per page (default 5)") { |v| options[:max_items] = v }
end.parse!(ARGV)

input = ARGV.fetch(0) { abort "Usage: bin/website_crawler_debug.rb <domain_or_url> [options]" }

def step(number, name)
  puts
  puts "=" * 78
  puts "[Step #{number}] #{name}"
  puts "=" * 78
end

def info(label, value)
  puts "  #{label}: #{value.inspect}"
end

# --- Step 1: resolve the WebsiteAccount -------------------------------------
step(1, "Resolve WebsiteAccount")

url = input.match?(%r{\Ahttps?://}i) ? input : "https://#{input}"
host = URI.parse(url).host.to_s
fakeid = host.sub(/\Awww\./, "")

account = WebsiteAccount.find_or_initialize_by(fakeid: fakeid)
was_new = account.new_record?
if was_new
  account.nickname = fakeid
  account.metadata = { "url" => url }
  account.status = :active
  account.total_articles = 0
  account.save!
end
account.metadata = (account.metadata || {}).merge("max_pages" => options[:max_pages]) if options[:max_pages]
account.save! if account.changed?

info("account_id", account.id)
info("created new record?", was_new)
info("fakeid", account.fakeid)
info("url", account.url)
info("max_pages", account.max_pages)
info("placeholder_nickname?", account.placeholder_nickname?)

# --- Step 2: run the real crawl pipeline ------------------------------------
step(2, "Run WebsiteCrawler.crawl_account (production entry point)")

crawl_task = CrawlTask.create!(account_ids: [account.id], status: :running, started_at: Time.current)
crawl_task.setup_account_tracking!
info("crawl_task_id", crawl_task.id)

result = WebsiteCrawler.crawl_account(account, crawl_task, article_concurrency: 1, max_pages: account.max_pages)
if result.is_a?(Hash)
  info("result", result.except(:pages))
  info("pages crawled", result[:pages]&.map(&:url))
  crawled_pages = result[:pages] || []
else
  info("result", "crawl_account raised (see crawl_logs below for the error)")
  crawled_pages = []
end

crawl_task.mark_complete_or_fail!
crawl_task.reload

# --- Step 3: replay crawl_logs produced by the run --------------------------
step(3, "crawl_logs produced during the run")

crawl_task.crawl_logs.order(:created_at).each_with_index do |log, i|
  puts "  #{i + 1}. [#{log.level}] #{log.message}"
end

# --- Step 4: per-page raw item extraction (debug the date_text pipeline) ---
step(4, "Per-page listing items: raw date_text -> parsed_date -> published_at")

fetcher = WebsiteCrawler::Fetcher.new
extractor = WebsiteCrawler::Extractor.new
synchronizer = WebsiteCrawler::ArticleSynchronizer.new
pages = crawled_pages

if pages.empty?
  puts "  (no monitor pages were crawled — discovery may have failed, see crawl_logs above)"
end

pages.each_with_index do |page, page_index|
  puts
  puts "  -- page #{page_index + 1}/#{pages.size}: #{page.url} (type=#{page.page_type}) --"

  fetch_result = fetcher.fetch(page.url)
  unless fetch_result.success?
    puts "     fetch failed: kind=#{fetch_result.kind} error=#{fetch_result.error}"
    next
  end

  items = extractor.extract_items(fetch_result.html, page.url)
  puts "     items found: #{items.size}"

  items.first(options[:max_items]).each_with_index do |item, i|
    parsed_date = synchronizer.send(:parse_date, item.date_text)
    article = Article.find_by(url: item.url)

    puts "     item[#{i}] title=#{item.title.inspect}"
    puts "              url=#{item.url}"
    puts "              date_text (raw, matched by DATE_PATTERN)=#{item.date_text.inspect}"
    puts "              parsed_date=#{parsed_date.inspect}#{' <- nil, so published_at fell back to Time.current' if parsed_date.nil?}"
    if article
      puts "              article.published_at=#{article.published_at} content_html_present=#{article.content_html.present?}"
    else
      puts "              article: not found (creation may have failed, see crawl_logs above)"
    end
  end
  puts "     ... #{items.size - options[:max_items]} more items not shown" if items.size > options[:max_items]
end

# --- Step 5: summary ---------------------------------------------------------
step(5, "Summary")
info("crawl_task status", crawl_task.status)
info("crawl_task.progress (articles synced)", crawl_task.progress)
info("crawl_task.error_count", crawl_task.error_count)
info("account.monitor_pages count", account.monitor_pages.count)
info("account.articles count", account.articles.count)
puts "\nDone."
