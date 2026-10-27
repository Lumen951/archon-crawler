require "test_helper"

class Website::ImporterTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "robot import is idempotent and preserves an intentionally inactive account" do
    ids = Website::Importer.import_robot_websites
    assert_equal 16, ids.size
    account = WebsiteAccount.find(ids.first)
    account.update!(status: :inactive)
    assert_equal ids, Website::Importer.import_robot_websites
    assert_predicate account.reload, :inactive?
  end

  test "robot scheduler limits evening membership and deduplicates slots" do
    Website::Importer.import_robot_websites
    clear_enqueued_jobs
    travel_to Time.zone.local(2026, 10, 27, 20) do
      ids = WebsiteAccount.enqueue_robot_checks("evening")
      assert_equal 3, ids.size
      assert_equal 3, enqueued_jobs.count { |job| job[:job] == CrawlJob }
      assert_empty WebsiteAccount.enqueue_robot_checks("evening")
      CrawlTask.where(id: ids).update_all(status: :completed)
      assert_empty WebsiteAccount.enqueue_robot_checks("evening")
    end
  end

  test "robot scheduler respects inactive accounts and pending work" do
    ids = Website::Importer.import_robot_websites
    WebsiteAccount.find(ids.first).update!(status: :inactive)
    CrawlTask.create!(account_ids: [ ids.second ], status: :pending)
    travel_to Time.zone.local(2026, 10, 27, 8) do
      assert_equal 14, WebsiteAccount.enqueue_robot_checks.size
    end
  end

  test "queue failure leaves a failed task and permits a later retry" do
    Website::Importer.import_robot_websites
    broken_queue = Object.new
    broken_queue.define_singleton_method(:perform_later) { |_| raise "queue unavailable" }
    stub_class_method(CrawlJob, :set, ->(**) { broken_queue }) do
      assert_raises(RuntimeError) { WebsiteAccount.enqueue_robot_checks }
    end
    task = CrawlTask.order(:id).last
    assert_predicate task, :failed?
    assert_match "queue unavailable", task.error_message
    assert_nil WebsiteAccount.find(task.account_ids.first).metadata.dig("monitoring_slots", "morning")
  end

  test "evening dispatch does not erase morning deduplication" do
    Website::Importer.import_robot_websites
    travel_to Time.zone.local(2026, 10, 27, 8) do
      morning = WebsiteAccount.enqueue_robot_checks("morning")
      CrawlTask.where(id: morning).update_all(status: :completed)
      evening = WebsiteAccount.enqueue_robot_checks("evening")
      CrawlTask.where(id: evening).update_all(status: :completed)
      assert_empty WebsiteAccount.enqueue_robot_checks("morning")
    end
  end

  test "imports named and bare URLs" do
    result = Website::Importer.import_lines([
      "DeepSeek, https://www.deepseek.com",
      "https://www.openai.com"
    ])

    assert_equal 2, result.imported_count
    assert_equal 0, result.skipped_count
    assert_equal 0, result.invalid_count

    deepseek = Account.find_by(fakeid: "deepseek.com")
    assert_equal "WebsiteAccount", deepseek.type
    assert_equal "DeepSeek", deepseek.nickname
    assert_equal "https://www.deepseek.com", deepseek.metadata["url"]

    openai = Account.find_by(fakeid: "openai.com")
    assert_equal "openai.com", openai.nickname
    assert_equal "https://www.openai.com", openai.metadata["url"]
  end

  test "accepts full-width comma and strips www for dedupe" do
    result = Website::Importer.import_lines([
      "Anthropic，https://www.anthropic.com",
      "https://anthropic.com" # same host, www-stripped → duplicate
    ])

    assert_equal 1, result.imported_count
    assert_equal 1, result.skipped_count
    assert_equal "Anthropic", Account.find_by(fakeid: "anthropic.com").nickname
  end

  test "normalizes scheme-less urls and trailing slashes" do
    result = Website::Importer.import_lines([ "DeepSeek, deepseek.com/" ])

    assert_equal 1, result.imported_count
    account = Account.find_by(fakeid: "deepseek.com")
    assert_equal "https://deepseek.com", account.metadata["url"]
  end

  test "creates a bare listing rule for asynchronous generation" do
    result = Website::Importer.import_lines([ "Events, https://events.example.com/list" ], crawl_mode: "listing")

    assert_equal 1, result.imported_count
    account = WebsiteAccount.find_by!(fakeid: "events.example.com")
    assert_equal({ "mode" => "listing" }, account.crawl_rule)
    assert account.listing_rule_unconfigured?
    assert_predicate account, :inactive?
    assert_equal [ account.id ], result.imported_account_ids
  end

  test "imports sitemap accounts as active" do
    result = Website::Importer.import_lines([ "Example, https://example.com" ])

    assert_equal 1, result.imported_count
    assert_predicate WebsiteAccount.find(result.imported_account_ids.first), :active?
  end

  test "rejects unsupported crawl modes" do
    assert_raises(ArgumentError) do
      Website::Importer.import_lines([ "https://example.com" ], crawl_mode: "browser")
    end
  end

  test "reports invalid lines" do
    result = Website::Importer.import_lines([ "not a url" ])

    assert_equal 0, result.imported_count
    assert_equal 1, result.invalid_count
    assert_equal 0, result.skipped_count
  end
end
