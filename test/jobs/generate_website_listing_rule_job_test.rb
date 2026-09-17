require "test_helper"

class GenerateWebsiteListingRuleJobTest < ActiveJob::TestCase
  test "persists a generated rule only for an unconfigured listing account" do
    account = WebsiteAccount.create!(
      fakeid: "job-example.com",
      nickname: "Job Example",
      metadata: { "url" => "https://job-example.com/events" },
      crawl_rule: { "mode" => "listing" },
      status: :inactive
    )
    generator = Object.new
    generator.define_singleton_method(:generate) do |_account|
      {
        "mode" => "listing",
        "entry_urls" => [ "https://job-example.com/events" ],
        "item_selector" => ".event-card",
        "url" => { "selector" => "a", "attribute" => "href" },
        "title" => { "selector" => "a" }
      }
    end

    stub_class_method(Website::ListingRuleGenerator, :new, -> { generator }) do
      GenerateWebsiteListingRuleJob.perform_now(account.id)
    end

    assert_equal ".event-card", account.reload.crawl_rule["item_selector"]
    assert_not account.listing_rule_unconfigured?
    assert_predicate account, :active?
  end

  test "leaves a listing account inactive when rule generation fails" do
    account = WebsiteAccount.create!(
      fakeid: "failed-job-example.com",
      nickname: "Failed Job Example",
      metadata: { "url" => "https://failed-job-example.com/events" },
      crawl_rule: { "mode" => "listing" },
      status: :inactive
    )
    generator = Object.new
    generator.define_singleton_method(:generate) do |_account|
      raise Website::ListingRuleGenerator::GenerationError, "invalid detail selector"
    end

    stub_class_method(Website::ListingRuleGenerator, :new, -> { generator }) do
      GenerateWebsiteListingRuleJob.perform_now(account.id)
    end

    assert_predicate account.reload, :inactive?
    assert_equal({ "mode" => "listing" }, account.crawl_rule)
  end
end
