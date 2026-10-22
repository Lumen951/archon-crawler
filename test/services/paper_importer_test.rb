require "test_helper"
require "webmock/minitest"

class PaperImporterTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email_address: "paper-service@example.test", password: "password123", email_confirmed_at: Time.current)
    @xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <feed xmlns="http://www.w3.org/2005/Atom">
        <entry>
          <id>http://arxiv.org/abs/1706.03762v7</id>
          <title>Attention Is All You Need</title>
          <summary>We propose a new simple network architecture.</summary>
          <published>2017-06-12T17:57:34Z</published>
          <updated>2023-08-02T00:41:18Z</updated>
          <author><name>Ashish Vaswani</name></author>
          <author><name>Noam Shazeer</name></author>
        </entry>
      </feed>
    XML
  end

  test "normalizes an arxiv version and persists ordered authors" do
    stub_request(:get, "https://export.arxiv.org/api/query?id_list=1706.03762v7&max_results=1").to_return(status: 200, body: @xml)

    paper = PaperImporter.import!("https://arxiv.org/pdf/1706.03762v7.pdf")

    assert_equal "Attention Is All You Need", paper.title
    assert_equal "1706.03762", paper.sources.first.external_id
    assert_equal 7, paper.sources.first.arxiv_version
    assert_equal [ "Ashish Vaswani", "Noam Shazeer" ], paper.authorships.order(:position).map(&:display_name)
  end

  test "rejects unsupported hosts before making a request" do
    error = assert_raises(PaperImporter::UnsupportedUrl) { PaperImporter.import!("https://example.com/paper") }

    assert_match "仅支持", error.message
  end

  test "html links preserve the requested version and reject a mismatched response" do
    stub_request(:get, "https://export.arxiv.org/api/query?id_list=1706.03762v7&max_results=1").to_return(body: @xml)
    paper = PaperImporter.import!("https://arxiv.org/html/1706.03762v7")
    assert_equal 7, paper.sources.first.arxiv_version
    stub_request(:get, "https://export.arxiv.org/api/query?id_list=1706.03762v1&max_results=1").to_return(body: @xml)
    assert_raises(PaperImporter::FetchError) { PaperImporter.import!("https://arxiv.org/html/1706.03762v1") }
  end

  test "import job schedules full text after metadata is saved" do
    stub_arxiv
    task = @user.paper_import_tasks.create!(total_count: 1)
    task.items.create!(url: "https://arxiv.org/abs/1706.03762")
    assert_enqueued_jobs 1, only: PaperFullTextDownloadJob do
      PaperImportJob.perform_now(task.id)
    end
    assert task.reload.completed?
    record = task.items.first.paper.sources.first.full_texts.first
    assert record.status_queued?
    assert_equal 7, record.version
  end

  test "abs pdf and version links keep one paper and stable signatures" do
    stub_arxiv
    paper = PaperImporter.import!("https://arxiv.org/abs/1706.03762")
    identities = paper.authorships.pluck(:paper_author_id)
    assert_no_difference [ "Paper.count", "PaperSource.count", "PaperAuthor.count" ] do
      assert_equal paper.id, PaperImporter.import!("https://arxiv.org/pdf/1706.03762v7.pdf").id
    end
    assert_equal identities, paper.reload.authorships.pluck(:paper_author_id)
    assert_equal paper, paper.authors.first.papers.first
  end

  test "same name on different papers is not automatically the same author" do
    stub_arxiv
    first = PaperImporter.import!("https://arxiv.org/abs/1706.03762")
    stub_request(:get, "https://export.arxiv.org/api/query?id_list=2401.00001&max_results=1")
      .to_return(body: @xml.gsub("1706.03762", "2401.00001"))
    second = PaperImporter.import!("https://arxiv.org/abs/2401.00001")
    assert_empty first.authors.ids & second.authors.ids
  end

  test "refresh updates author order and removes stale signatures" do
    stub_arxiv
    paper = PaperImporter.import!("https://arxiv.org/abs/1706.03762")
    stub_arxiv(@xml.sub("<author><name>Ashish Vaswani</name></author>", ""))
    PaperImporter.import!("https://arxiv.org/abs/1706.03762")
    assert_equal [ "Noam Shazeer" ], paper.reload.authorships.pluck(:display_name)
  end

  test "arxiv errors mismatched IDs and invalid XML create no records" do
    [ @xml.sub("1706.03762v7", "2401.00001v1"), "<feed>", "<feed/>" ] .each do |body|
      stub_arxiv(body)
      assert_no_difference [ "Paper.count", "PaperSource.count", "PaperAuthor.count" ] do
        assert_raises(PaperImporter::FetchError) { PaperImporter.import!("https://arxiv.org/abs/1706.03762") }
      end
    end
  end

  test "persistence failure rolls back the whole import" do
    stub_arxiv
    stub_class_method(PaperAuthor, :create!, ->(**) { raise ActiveRecord::RecordInvalid }) do
      assert_no_difference [ "Paper.count", "PaperSource.count" ] do
        assert_raises(ActiveRecord::RecordInvalid) { PaperImporter.import!("https://arxiv.org/abs/1706.03762") }
      end
    end
  end

  test "rejects malformed paths credentials and custom ports" do
    %w[https://arxiv.org/abs/1706.03762/other https://arxiv.org:444/abs/1706.03762
       https://user@arxiv.org/abs/1706.03762 https://openreview.net/group?id=abc
       https://openreview.net/forum?id=abc%2Fdef].each do |url|
      assert_raises(PaperImporter::UnsupportedUrl) { PaperImporter.import!(url) }
    end
  end

  test "openreview v2 preserves profile IDs order and millisecond modification date" do
    stub_openreview
    paper = PaperImporter.import!("https://openreview.net/forum?id=example")
    assert_equal "Example paper", paper.title
    assert_equal [ "~Example_Author1", nil ], paper.authors.pluck(:external_id)
    assert_nil paper.published_at
    assert_equal Time.at(1_700_000_000), paper.updated_at_source
    assert_no_difference "Paper.count" do
      PaperImporter.import!("https://openreview.net/pdf?id=example")
    end
  end

  test "openreview rejects replies invalid JSON and inaccessible notes" do
    [ JSON.generate(notes: [ { id: "example", forum: "other" } ]), "invalid", JSON.generate(notes: []) ].each do |body|
      stub_request(:get, "https://api2.openreview.net/notes?id=example&limit=1").to_return(body: body)
      assert_raises(PaperImporter::FetchError) { PaperImporter.import!("https://openreview.net/forum?id=example") }
    end
    [ 403, 429, 503 ].each do |status|
      stub_request(:get, "https://api2.openreview.net/notes?id=example&limit=1").to_return(status: status)
      error = assert_raises(PaperImporter::FetchError) { PaperImporter.import!("https://openreview.net/forum?id=example") }
      assert_includes error.message, status.to_s
    end
  end

  test "timeout becomes an actionable fetch failure" do
    stub_request(:get, "https://api2.openreview.net/notes?id=example&limit=1").to_timeout
    assert_raises(PaperImporter::FetchError) { PaperImporter.import!("https://openreview.net/forum?id=example") }
  end

  test "openreview unified authors preserve names profile IDs and publication time" do
    note = { id: "example", forum: "example", pdate: 1_700_000_000_000,
      content: { title: { value: "Unified authors" }, authors: { value: [ { fullname: "First Author" }, { fullname: "Last Author" } ] },
        authorids: { value: [ { username: "~First_Author1" }, { username: "~Last_Author1" } ] } } }
    stub_request(:get, "https://api2.openreview.net/notes?id=example&limit=1").to_return(body: { notes: [ note ] }.to_json)
    paper = PaperImporter.import!("https://openreview.net/forum?id=example")
    assert_equal [ "First Author", "Last Author" ], paper.authorships.pluck(:display_name)
    assert_equal [ "~First_Author1", "~Last_Author1" ], paper.authors.pluck(:external_id)
    assert_equal Time.at(1_700_000_000), paper.published_at
  end

  test "oversized response and malformed JSON shape do not persist papers" do
    [ "x" * (2.megabytes + 1), "[]" ].each do |body|
      stub_request(:get, "https://api2.openreview.net/notes?id=example&limit=1").to_return(body: body)
      assert_no_difference "Paper.count" do
        assert_raises(PaperImporter::FetchError) { PaperImporter.import!("https://openreview.net/forum?id=example") }
      end
    end
  end

  test "job records partial failure and repeated delivery does not change counts" do
    stub_openreview
    task = @user.paper_import_tasks.create!(total_count: 2)
    task.items.create!(url: "https://openreview.net/forum?id=example")
    task.items.create!(url: "https://example.com/unsupported")
    PaperImportJob.perform_now(task.id)
    assert_equal [ "failed", 2, 1, 1 ], task.reload.attributes.values_at("status", "processed_count", "imported_count", "failed_count")
    assert_no_difference "Paper.count" do
      PaperImportJob.perform_now(task.id)
    end
    assert_equal 2, task.reload.processed_count
    assert task.items.failed.first.error_message.present?
  end

  test "redelivery resumes running tasks and item accounting is idempotent" do
    stub_openreview
    task = @user.paper_import_tasks.create!(total_count: 1, status: :running)
    item = task.items.create!(url: "https://openreview.net/forum?id=example")
    PaperImportJob.perform_now(task.id)
    assert task.reload.completed?
    task.record_failed!(item.reload, "late failure")
    assert_equal [ 1, 1, 0 ], task.reload.attributes.values_at("processed_count", "imported_count", "failed_count")
  end

  test "rate limit preserves retry after seconds and dates without persisting" do
    travel_to Time.utc(2026, 10, 22, 12) do
      { "180" => 180, 5.minutes.from_now.httpdate => 300, "bad" => nil }.each do |header, expected|
        stub_request(:get, "https://api2.openreview.net/notes?id=example&limit=1")
          .to_return(status: 429, headers: { "Retry-After" => header })
        assert_no_difference "Paper.count" do
          error = assert_raises(PaperImporter::TemporaryError) { PaperImporter.import!("https://openreview.net/forum?id=example") }
          expected.nil? ? assert_nil(error.retry_after) : assert_equal(expected, error.retry_after)
        end
      end
    end
  end

  test "timeout has a distinct retryable error" do
    stub_request(:get, "https://api2.openreview.net/notes?id=example&limit=1").to_timeout
    error = assert_raises(PaperImporter::TemporaryError) { PaperImporter.import!("https://openreview.net/forum?id=example") }
    assert_equal "来源请求超时", error.message
  end

  test "retry leaves counters pending then succeeds without duplication" do
    task = @user.paper_import_tasks.create!(total_count: 1)
    item = task.items.create!(url: "https://openreview.net/forum?id=example")
    stub_request(:get, "https://api2.openreview.net/notes?id=example&limit=1")
      .to_return(status: 429, headers: { "Retry-After" => "180" })
    travel_to Time.utc(2026, 10, 22, 12) do
      assert_enqueued_with(job: PaperImportJob, args: [task.id, { item.id.to_s => 1 }], at: 180.seconds.from_now) do
        PaperImportJob.perform_now(task.id)
      end
    end
    assert task.reload.running?
    assert_equal 0, task.processed_count
    assert item.reload.pending?
    assert_includes task.error_message, "180"
    stub_openreview
    PaperImportJob.perform_now(task.id, { item.id.to_s => 1 })
    assert task.reload.completed?
    assert_equal 1, task.imported_count
    assert_nil task.error_message
    assert_no_difference "Paper.count" do
      PaperImportJob.perform_now(task.id, { item.id.to_s => 1 })
    end
  end

  test "exhausted retries fail once and continue remaining items" do
    task = @user.paper_import_tasks.create!(total_count: 2)
    item = task.items.create!(url: "https://openreview.net/forum?id=limited")
    task.items.create!(url: "https://openreview.net/forum?id=example")
    stub_request(:get, "https://api2.openreview.net/notes?id=limited&limit=1").to_return(status: 429)
    stub_openreview
    assert_no_enqueued_jobs do
      PaperImportJob.perform_now(task.id, { item.id.to_s => 2 })
    end
    assert_equal [ "failed", 2, 1, 1 ], task.reload.attributes.values_at("status", "processed_count", "imported_count", "failed_count")
    assert_includes item.reload.error_message, "自动重试已耗尽"
  end

  test "retry enqueue failure is recorded rather than left running" do
    task = @user.paper_import_tasks.create!(total_count: 1)
    task.items.create!(url: "https://openreview.net/forum?id=example")
    stub_request(:get, "https://api2.openreview.net/notes?id=example&limit=1").to_return(status: 503)
    stub_class_method(PaperImportJob, :set, ->(**) { raise ActiveJob::EnqueueError }) do
      PaperImportJob.perform_now(task.id)
    end
    assert task.reload.failed?
    assert_equal 1, task.failed_count
    assert_includes task.items.first.error_message, "未能入队"
  end

  test "second retry backs off and excessive retry after is not shortened" do
    task = @user.paper_import_tasks.create!(total_count: 1)
    item = task.items.create!(url: "https://openreview.net/forum?id=example")
    stub_request(:get, "https://api2.openreview.net/notes?id=example&limit=1").to_return(status: 503)
    travel_to Time.utc(2026, 10, 22, 12) do
      assert_enqueued_with(job: PaperImportJob, args: [task.id, { item.id.to_s => 2 }], at: 120.seconds.from_now) do
        PaperImportJob.perform_now(task.id, { item.id.to_s => 1 })
      end
    end
    stub_request(:get, "https://api2.openreview.net/notes?id=example&limit=1")
      .to_return(status: 429, headers: { "Retry-After" => "7200" })
    assert_no_enqueued_jobs do
      PaperImportJob.perform_now(task.id, { item.id.to_s => 1 })
    end
    assert task.reload.failed?
    assert_includes item.reload.error_message, "超过一小时"
  end

  private

  def stub_arxiv(body = @xml)
    stub_request(:get, "https://export.arxiv.org/api/query?id_list=1706.03762&max_results=1").to_return(body: body)
    stub_request(:get, "https://export.arxiv.org/api/query?id_list=1706.03762v7&max_results=1").to_return(body: body)
  end

  def stub_openreview
    payload = { notes: [ { id: "example", forum: "example", tmdate: 1_700_000_000_000,
      content: { title: { value: "Example paper" }, abstract: { value: "Summary" },
        authors: { value: [ "Example Author", "Anonymous" ] }, authorids: { value: [ "~Example_Author1", "private@example.test" ] } } } ] }
    stub_request(:get, "https://api2.openreview.net/notes?id=example&limit=1").to_return(body: JSON.generate(payload))
  end
end
