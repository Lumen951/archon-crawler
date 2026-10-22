require "test_helper"

class PaperFullTextDownloadJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    paper = Paper.create!(title: "Job test")
    source = paper.sources.create!(provider: :arxiv, external_id: "2401.00001",
      canonical_url: "https://arxiv.org/abs/2401.00001", raw_metadata: { version: 1 })
    @record = source.prepare_full_text!
    @record.update!(status: :queued, run_token: "current-run")
  end

  test "successful download and duplicate or obsolete deliveries are safe" do
    calls = 0
    success = lambda do
      calls += 1
      @record.update!(status: :ready, downloaded_at: Time.current)
    end
    with_download(success) do
      PaperFullTextDownloadJob.perform_now(@record.id, "old-run")
      assert_equal 0, calls
      2.times { PaperFullTextDownloadJob.perform_now(@record.id, "current-run") }
      assert_equal 1, calls
      assert @record.reload.status_ready?
    end
  end

  test "temporary failures wait before retry without failing metadata" do
    with_download(-> { raise PaperImporter::TemporaryError.new("limited", retry_after: 180) }) do
      travel_to Time.utc(2026, 10, 22, 12) do
        assert_enqueued_with(job: PaperFullTextDownloadJob, args: [ @record.id, "current-run", 1 ], at: 180.seconds.from_now) do
          PaperFullTextDownloadJob.perform_now(@record.id, "current-run")
        end
        assert @record.reload.status_queued?
        refute @record.retryable?
        assert_no_enqueued_jobs do
          PaperFullTextDownloadJob.perform_now(@record.id, "current-run")
        end
        assert_equal 180.seconds.from_now, @record.reload.retry_at
      end
    end
    assert_equal "Job test", @record.paper_source.paper.title
  end

  test "exhaustion and long retry after remain visible and block early manual retry" do
    with_download(-> { raise PaperImporter::TemporaryError.new("limited", retry_after: 7200) }) do
      assert_no_enqueued_jobs { PaperFullTextDownloadJob.perform_now(@record.id, "current-run", 2) }
      assert @record.reload.status_failed?
      refute @record.retryable?
      assert_includes @record.error_message, "自动重试已停止"
    end
  end

  test "unavailable HTML is not a successful full text" do
    with_download(-> { raise PaperFullTextDownloader::Unavailable }) do
      PaperFullTextDownloadJob.perform_now(@record.id, "current-run")
      assert @record.reload.status_unavailable?
      assert_nil @record.downloaded_at
    end
  end

  test "failed enqueue is recorded and active download cannot be queued twice" do
    assert_no_enqueued_jobs { refute @record.enqueue! }
    @record.update!(status: :failed)
    stub_class_method(PaperFullTextDownloadJob, :perform_later, ->(*) { false }) do
      refute @record.enqueue!
    end
    assert @record.reload.status_failed?
    assert_includes @record.error_message, "未能入队"
  end

  test "retry enqueue failure does not leave a running download" do
    with_download(-> { raise PaperImporter::TemporaryError, "timeout" }) do
      stub_class_method(PaperFullTextDownloadJob, :set, ->(**) { raise ActiveJob::EnqueueError }) do
        PaperFullTextDownloadJob.perform_now(@record.id, "current-run")
      end
    end
    assert @record.reload.status_failed?
    assert_includes @record.error_message, "未能入队"
  end

  private

  def with_download(implementation, &block)
    downloader = Object.new
    downloader.define_singleton_method(:download!) { implementation.call }
    stub_class_method(PaperFullTextDownloader, :new, ->(*) { downloader }, &block)
  end
end
