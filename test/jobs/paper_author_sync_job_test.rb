require "test_helper"

class PaperAuthorSyncJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FastJob < PaperAuthorSyncJob
    def sleep(_seconds); end
  end

  setup do
    user = User.create!(email_address: "author-job@example.test", password: "password123", email_confirmed_at: Time.current)
    paper = Paper.create!(title: "Seed")
    author = PaperAuthor.create!(display_name: "Example Author", provider: "arxiv")
    @subscription = user.paper_subscriptions.create!(paper_author: author, seed_paper: paper,
      display_name: author.display_name, name_variants: [ author.display_name ])
    @run = @subscription.sync_runs.create!(run_token: "current", cutoff_at: Time.current, name_variants: @subscription.name_variants)
  end

  test "each page commits before scheduling next and stale deliveries do nothing" do
    page = PaperAuthorDiscovery::Page.new([ Object.new ], 2)
    calls = 0
    discovery = Object.new
    discovery.define_singleton_method(:fetch_page) { page }
    discovery.define_singleton_method(:save_page!) { |_| calls += 1 }
    stub_class_method(PaperAuthorDiscovery, :new, ->(*) { discovery }) do
      assert_enqueued_jobs 1, only: PaperAuthorSyncJob do
        FastJob.perform_now(@run.id, "current", 0)
      end
      assert_equal 1, @run.reload.next_offset
      assert @run.queued?
      assert_no_enqueued_jobs do
        FastJob.perform_now(@run.id, "current", 0)
        FastJob.perform_now(@run.id, "obsolete", 1)
      end
      FastJob.perform_now(@run.id, "current", 1)
      assert @run.reload.completed?
      assert_equal 2, calls
      assert_equal 2, @run.page_count
    end
  end

  test "failed page rolls back metadata and checkpoint" do
    discovery = Object.new
    discovery.define_singleton_method(:fetch_page) { PaperAuthorDiscovery::Page.new([ Object.new ], 1) }
    discovery.define_singleton_method(:save_page!) do |_|
      Paper.create!(title: "Must roll back")
      raise PaperImporter::FetchError, "broken"
    end
    stub_class_method(PaperAuthorDiscovery, :new, ->(*) { discovery }) do
      assert_no_difference("Paper.count") { FastJob.perform_now(@run.id, "current", 0) }
    end
    assert @run.reload.failed?
    assert_equal 0, @run.next_offset
    assert_equal "broken", @run.error_message
  end

  test "pause during network request prevents page commit and next enqueue" do
    subscription = @subscription
    discovery = Object.new
    discovery.define_singleton_method(:fetch_page) do
      subscription.pause!
      PaperAuthorDiscovery::Page.new([], 0)
    end
    discovery.define_singleton_method(:save_page!) { |_| raise "must not save" }
    stub_class_method(PaperAuthorDiscovery, :new, ->(*) { discovery }) do
      assert_no_enqueued_jobs { FastJob.perform_now(@run.id, "current", 0) }
    end
    assert @run.reload.paused?
    assert_equal 0, @run.page_count
  end

  test "rate limit delays retry and exhausted retries remain resumable later" do
    discovery = Object.new
    discovery.define_singleton_method(:fetch_page) { raise PaperImporter::TemporaryError.new("limited", retry_after: 180) }
    stub_class_method(PaperAuthorDiscovery, :new, ->(*) { discovery }) do
      travel_to Time.utc(2026, 10, 22, 12) do
        assert_enqueued_with(job: PaperAuthorSyncJob, args: [ @run.id, "current", 0, 1 ], at: 180.seconds.from_now) do
          FastJob.perform_now(@run.id, "current", 0)
        end
        assert_no_enqueued_jobs { FastJob.perform_now(@run.id, "current", 0, 1) }
        assert_equal 0, @run.reload.next_offset
        travel 180.seconds
        assert_no_enqueued_jobs { FastJob.perform_now(@run.id, "current", 0, 2) }
        assert @run.reload.failed?
        refute @run.resumable?
        travel 240.seconds
        assert @run.reload.resumable?
      end
    end
  end

  test "enqueue failure after page leaves committed checkpoint recoverable" do
    discovery = Object.new
    discovery.define_singleton_method(:fetch_page) { PaperAuthorDiscovery::Page.new([ Object.new ], 2) }
    discovery.define_singleton_method(:save_page!) { |_| }
    stub_class_method(PaperAuthorDiscovery, :new, ->(*) { discovery }) do
      stub_class_method(PaperAuthorSyncJob, :set, ->(**) { raise ActiveJob::EnqueueError }) do
        FastJob.perform_now(@run.id, "current", 0)
      end
    end
    assert @run.reload.failed?
    assert_equal 1, @run.next_offset
    assert_equal 1, @run.page_count
  end
end
