require "test_helper"
require "tmpdir"

class PapersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email_address: "papers@example.com",
      password: "password123",
      password_confirmation: "password123",
      role: :admin,
      email_confirmed_at: Time.current
    )
    post session_path, params: { email_address: @user.email_address, password: "password123" }
  end

  test "renders the shared paper import entry" do
    get import_papers_path

    assert_response :success
    assert_select "h1", text: "论文导入"
    assert_select "textarea[name='paper_import[urls]']"
  end

  test "creates an asynchronous import task for multiple links" do
    assert_difference -> { PaperImportTask.count }, 1 do
      post create_import_papers_path, params: { paper_import: { urls: "https://arxiv.org/abs/1706.03762\nhttps://openreview.net/forum?id=abc" } }
    end

    task = PaperImportTask.order(:id).last
    assert_redirected_to paper_import_task_path(task)
    assert_equal 2, task.items.count
  end

  test "rejects oversized batches without creating a task" do
    assert_no_difference "PaperImportTask.count" do
      post create_import_papers_path, params: { paper_import: { urls: (1..21).map { |i| "https://openreview.net/forum?id=#{i}" }.join("\n") } }
    end
    assert_response :unprocessable_entity
  end

  test "enqueue failure is visible on the saved task" do
    stub_class_method(PaperImportJob, :perform_later, ->(*) { raise ActiveJob::EnqueueError, "unavailable" }) do
      post create_import_papers_path, params: { paper_import: { urls: "https://arxiv.org/abs/1706.03762" } }
    end
    task = @user.paper_import_tasks.last
    assert task.failed?
    assert task.error_message.present?
    follow_redirect!
    assert_response :success
    assert_select "a", text: "重新导入"
  end

  test "poll includes completed titles links and escaped errors" do
    task = @user.paper_import_tasks.create!(total_count: 2)
    paper = Paper.create!(title: "<script>Example</script>")
    task.items.create!(url: "https://openreview.net/forum?id=example", status: :imported, paper: paper)
    task.items.create!(url: "https://example.test", status: :failed, error_message: "<script>error</script>")
    task.update!(status: :failed, processed_count: 2, imported_count: 1, failed_count: 1)
    get poll_paper_import_task_path(task), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_includes response.body, "target=\"paper_import_task\""
    assert_includes response.body, paper_path(paper)
    assert_includes response.body, "&lt;script&gt;error&lt;/script&gt;"
    get papers_path
    assert_response :success
    get paper_path(paper)
    assert_response :success
  end

  test "users cannot inspect someone else's task or poll" do
    owner = User.create!(email_address: "paper-owner@example.test", password: "password123", email_confirmed_at: Time.current)
    task = owner.paper_import_tasks.create!
    get paper_import_task_path(task)
    assert_response :not_found
    get poll_paper_import_task_path(task), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :not_found
  end

  test "existing paper can request full text without another metadata import" do
    paper = Paper.create!(title: "Existing paper")
    source = paper.sources.create!(provider: :arxiv, external_id: "2401.00001",
      canonical_url: "https://arxiv.org/abs/2401.00001", raw_metadata: { version: 1 })
    assert_difference "PaperFullText.count", 1 do
      post download_full_text_paper_path(paper), params: { source_id: source.id }
    end
    assert_redirected_to paper_path(paper)
    assert source.full_texts.first.status_queued?
    assert_no_difference "PaperFullText.count" do
      post download_full_text_paper_path(paper), params: { source_id: source.id }
    end
    assert_response :redirect
  end

  test "full text and assets require login and cannot cross paper boundaries" do
    paper = Paper.create!(title: "Readable paper")
    other = Paper.create!(title: "Different paper")
    source = paper.sources.create!(provider: :arxiv, external_id: "2401.00001",
      canonical_url: "https://arxiv.org/abs/2401.00001", raw_metadata: { version: 1 })
    record = source.prepare_full_text!
    key = "a" * 64
    record.update!(status: :ready, downloaded_at: Time.current, resources: { key => { "type" => "image/png" } })
    Dir.mktmpdir("paper-reader-test") do |directory|
      stub_class_method(PaperFullText, :storage_root, -> { Pathname.new(directory) }) do
        FileUtils.mkdir_p(record.directory)
        File.write(record.html_path, "<article><h1>Local body</h1><math><mi>x</mi></math><script>alert(1)</script></article>")
        File.binwrite(record.directory.join(key), "PNG test bytes")
        get read_paper_path(paper, full_text_id: record.id)
        assert_response :success
        assert_select "math mi", text: "x"
        assert_includes response.headers["Content-Security-Policy"], "default-src 'none'"
        assert_select "script", count: 0
        get full_text_asset_paper_path(paper, full_text_id: record.id, resource: key)
        assert_response :success
        assert_equal "image/png", response.media_type
        get full_text_asset_paper_path(paper, full_text_id: record.id, resource: "../article.html")
        assert_response :not_found
        get read_paper_path(other, full_text_id: record.id)
        assert_response :not_found
        post download_full_text_paper_path(other), params: { source_id: source.id }
        assert_response :not_found
        delete session_path
        get read_paper_path(paper, full_text_id: record.id)
        assert_redirected_to new_session_path
        get full_text_asset_paper_path(paper, full_text_id: record.id, resource: key)
        assert_redirected_to new_session_path
      end
    end
  end
end
