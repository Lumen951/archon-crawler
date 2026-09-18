require "test_helper"

class Website::ImporterTest < ActiveSupport::TestCase
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
    result = Website::Importer.import_lines(["DeepSeek, deepseek.com/"])

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
    result = Website::Importer.import_lines(["not a url"])

    assert_equal 0, result.imported_count
    assert_equal 1, result.invalid_count
    assert_equal 0, result.skipped_count
  end
end
