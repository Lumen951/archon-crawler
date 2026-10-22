require "test_helper"

class PaperSubscriptionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    user = User.create!(email_address: "subscription@example.test", password: "password123", email_confirmed_at: Time.current)
    paper = Paper.create!(title: "Seed")
    author = PaperAuthor.create!(display_name: "Example Author", provider: "arxiv")
    @subscription = user.paper_subscriptions.create!(paper_author: author, seed_paper: paper,
      display_name: author.display_name, name_variants: [ author.display_name ])
  end

  test "starting twice keeps one active run with fixed query" do
    assert_difference "PaperSyncRun.count", 1 do
      assert_enqueued_jobs 1, only: PaperAuthorSyncJob do
        first = @subscription.start_sync!
        assert_equal first.id, @subscription.start_sync!.id
        assert_equal [ "Example Author" ], first.name_variants
        assert first.cutoff_at.present?
      end
    end
  end

  test "pause invalidates old delivery and resume retains checkpoint" do
    run = @subscription.start_sync!
    run.update!(next_offset: 50, total_count: 75)
    token = run.run_token
    @subscription.pause!
    assert run.reload.paused?
    refute_equal token, run.run_token
    assert_nil @subscription.resume_sync!
    @subscription.update!(enabled: true)
    assert_enqueued_jobs 1, only: PaperAuthorSyncJob do
      assert_equal run.id, @subscription.resume_sync!.id
    end
    assert_equal 50, run.reload.next_offset
  end

  test "aliases reject query syntax and cannot change a resumed query" do
    [ [], [ "Example\" OR all:robot" ], [ "*" ], Array.new(6, "Example Author") ].each do |names|
      @subscription.name_variants = names
      refute @subscription.valid?
    end
    @subscription.reload
    run = @subscription.start_sync!
    @subscription.pause!
    @subscription.update!(enabled: true, name_variants: [ "Another Name" ])
    assert_nil @subscription.resume_sync!
    assert_equal [ "Example Author" ], run.reload.name_variants
  end

  test "enqueue failures are visible and long retry delays cannot be bypassed" do
    stub_class_method(PaperAuthorSyncJob, :set, ->(**) { raise ActiveJob::EnqueueError }) do
      run = @subscription.start_sync!
      assert run.failed?
      assert_includes run.error_message, "未能入队"
      run.update!(retry_at: 2.hours.from_now)
      assert_nil @subscription.resume_sync!
      assert_no_difference "PaperSyncRun.count" do
        @subscription.start_sync!
      end
    end
  end

  test "stale jobs are manually resumable and confirmed decisions are explicit" do
    run = @subscription.start_sync!
    run.update!(updated_at: 11.minutes.ago)
    assert run.resumable?
    assert_equal run.id, @subscription.resume_sync!.id
    source = @subscription.seed_paper.sources.create!(provider: "arxiv", external_id: "2401.00001",
      canonical_url: "https://arxiv.org/abs/2401.00001", raw_metadata: { "version" => 1 })
    match = @subscription.matches.create!(paper_source: source)
    assert_enqueued_jobs 1, only: PaperFullTextDownloadJob do
      match.review!("confirmed")
    end
    assert match.reload.confirmed?
    assert match.reviewed_at.present?
    match.review!("excluded")
    assert match.excluded?
    assert_raises(ArgumentError) { match.review!("invalid") }
  end

  test "restarting a stale run invalidates its old token" do
    run = @subscription.start_sync!
    old_token = run.run_token
    run.update!(updated_at: 11.minutes.ago)
    replacement = @subscription.start_sync!
    refute_equal run.id, replacement.id
    assert run.reload.paused?
    refute_equal old_token, run.run_token
  end
end
