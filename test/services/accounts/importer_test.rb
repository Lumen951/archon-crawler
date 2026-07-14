require "test_helper"
require "tempfile"

class Accounts::ImporterTest < ActiveSupport::TestCase
  test "imports accounts from json text" do
    result = Accounts::Importer.import_text({
      accounts: [
        {
          fakeid: "json_fakeid_1",
          nickname: "JSON Account",
          round_head_img: "http://example.com/json.png",
          articles: 8
        }
      ]
    }.to_json)

    assert_equal 1, result.imported_count
    assert_equal 0, result.skipped_count
    assert_equal 0, result.invalid_count

    account = Account.find_by(fakeid: "json_fakeid_1")
    assert_equal "JSON Account", account.nickname
    assert_equal "http://example.com/json.png", account.round_head_img
    assert_equal 8, account.total_articles
  end

  test "imports csv with extra columns and reordered headers" do
    csv = <<~CSV
      nickname,extra column,fakeid,articles
      CSV Account,ignored,csv_fakeid_1,15
    CSV

    result = Accounts::Importer.import_file(upload_for("accounts.csv", csv))

    assert_equal 1, result.imported_count
    assert_equal 0, result.invalid_count

    account = Account.find_by(fakeid: "csv_fakeid_1")
    assert_equal "CSV Account", account.nickname
    assert_equal 15, account.total_articles
  end

  test "raises when csv is missing required headers" do
    csv = <<~CSV
      nickname_only,articles
      CSV Account,15
    CSV

    error = assert_raises(ArgumentError) do
      Accounts::Importer.import_file(upload_for("accounts.csv", csv))
    end

    assert_equal "文件缺少必填列：fakeid, nickname", error.message
  end

  test "imports xlsx with extra columns" do
    result = Accounts::Importer.import_file(fixture_upload("accounts_import.xlsx"))

    assert_equal 2, result.imported_count
    assert_equal 0, result.skipped_count
    assert_equal 0, result.invalid_count

    account = Account.find_by(fakeid: "xpath_fakeid_1")
    assert_equal "XLSX Account 1", account.nickname
    assert_equal 12, account.total_articles
  end

  test "skips duplicates and rows missing required values" do
    WechatAccount.create!(fakeid: "dup_fakeid", nickname: "Existing Account", status: :active)

    csv = <<~CSV
      fakeid,nickname,round_head_img,articles
      dup_fakeid,Duplicate Account,http://example.com/dup.png,10
      missing_nickname,,http://example.com/missing.png,4
      fresh_fakeid,Fresh Account,http://example.com/fresh.png,6
    CSV

    result = Accounts::Importer.import_file(upload_for("accounts.csv", csv))

    assert_equal 1, result.imported_count
    assert_equal 1, result.skipped_count
    assert_equal 1, result.invalid_count

    account = Account.find_by(fakeid: "fresh_fakeid")
    assert_equal "Fresh Account", account.nickname
  end

  private

  def upload_for(filename, content)
    file = Tempfile.new([File.basename(filename, ".*"), File.extname(filename)])
    file.binmode
    file.write(content)
    file.rewind

    ActionDispatch::Http::UploadedFile.new(
      tempfile: file,
      filename: filename,
      type: Mime::Type.lookup_by_extension(File.extname(filename).delete_prefix(".")).to_s
    )
  end

  def fixture_upload(filename)
    ActionDispatch::Http::UploadedFile.new(
      tempfile: File.open(Rails.root.join("test/fixtures/files", filename), "rb"),
      filename: filename,
      type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    )
  end
end
