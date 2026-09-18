class GenerateWebsiteListingRuleJob < ApplicationJob
  queue_as :default

  def perform(account_id)
    account = WebsiteAccount.find_by(id: account_id)
    return unless account&.listing_rule_unconfigured?

    rule = Website::ListingRuleGenerator.new.generate(account)
    account.update!(crawl_rule: rule, status: :active)
  rescue Website::ListingRuleGenerator::GenerationError => e
    Rails.logger.warn("Website listing rule generation failed for account ##{account_id}: #{e.message}")
  rescue StandardError => e
    Rails.logger.error("Website listing rule generation crashed for account ##{account_id}: #{e.class}: #{e.message}")
  end
end
