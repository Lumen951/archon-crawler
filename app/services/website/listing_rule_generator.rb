require "ferrum"

module Website
  # Produces a validated listing rule without creating Articles or starting a
  # crawl. A proposed rule must extract both listing candidates and a readable
  # detail body before it can be persisted. Static HTML is always preferred;
  # Ferrum is used only when that DOM cannot produce a verified result.
  class ListingRuleGenerator
    class GenerationError < StandardError; end

    DETAIL_SAMPLE_SIZE = 2
    GENERATED_MAX_ITEMS = 5
    GENERATED_MIN_INTERVAL_SECONDS = 10

    def initialize(fetcher: WebsiteCrawler::Fetcher.new, renderer: FerrumRenderer.new, llm: LlmClient.new)
      @fetcher = fetcher
      @renderer = renderer
      @llm = llm
    end

    def generate(account)
      raise GenerationError, "未配置 OpenAI API 密钥，无法自动生成 Listing 抓取规则" if @llm.is_a?(LlmClient) && !LlmClient.configured?

      entry_url = account.url
      direct_result = @fetcher.fetch(entry_url)
      rule = rule_from_listing_result(account, entry_url, direct_result)
      return rule if rule

      rendered_result = @renderer.fetch(entry_url)
      rule = rule_from_listing_result(account, entry_url, rendered_result)
      return rule if rule

      raise GenerationError, "未能生成同时通过列表和详情页验证的抓取规则"
    end

    private

    def rule_from_listing_result(account, entry_url, result)
      return nil unless result.success?

      proposal = @llm.generate_json(listing_prompt(entry_url, result.html))
      definition = proposal.respond_to?(:to_h) ? proposal.to_h.deep_stringify_keys : nil
      return nil unless definition

      definition["mode"] = "listing"
      definition["entry_urls"] = [ entry_url ]
      apply_conservative_limits!(definition)
      rule = WebsiteCrawler::ListingRule.new(account, definition)
      candidates = WebsiteCrawler::ListingExtractor.new(rule).extract(result.html, entry_url)
      return nil if candidates.size < DETAIL_SAMPLE_SIZE

      selector = detail_selector_for(candidates.first(DETAIL_SAMPLE_SIZE))
      return nil unless selector

      definition["detail"] = { "content_selector" => selector }
      WebsiteCrawler::ListingRule.new(account, definition).definition
    rescue WebsiteCrawler::ListingRule::InvalidRule, LlmClient::ApiError, JSON::ParserError => e
      Rails.logger.info("Website listing rule proposal rejected for #{entry_url}: #{e.message}")
      nil
    end

    def detail_selector_for(candidates)
      first_candidate = candidates.first
      [ @fetcher.fetch(first_candidate.url), @renderer.fetch(first_candidate.url) ].each do |result|
        next unless result.success?

        selector = detail_selector_from(result.html, first_candidate.url)
        next unless selector
        return selector if candidates.all? { |candidate| detail_content_available?(candidate.url, selector) }
      end

      nil
    end

    def detail_selector_from(html, url)
      proposal = @llm.generate_json(detail_prompt(url, html))
      selector = proposal.respond_to?(:[]) ? proposal["content_selector"].to_s.strip : ""
      return nil if selector.blank?

      usable_detail_content?(html, url, selector) ? selector : nil
    rescue LlmClient::ApiError, JSON::ParserError => e
      Rails.logger.info("Website listing detail selector rejected for #{url}: #{e.message}")
      nil
    end

    def detail_content_available?(url, selector)
      direct = @fetcher.fetch(url)
      return true if direct.success? && usable_detail_content?(direct.html, url, selector)

      rendered = @renderer.fetch(url)
      rendered.success? && usable_detail_content?(rendered.html, url, selector)
    end

    def usable_detail_content?(html, url, selector)
      extracted = WebsiteCrawler::Extractor.new.extract_article(
        html,
        url,
        selector: selector,
        allow_body_fallback: false,
        minimum_text_length: WebsiteCrawler::Extractor::LISTING_MIN_ARTICLE_TEXT_LENGTH
      )
      WebsiteCrawler::ListingArticleSynchronizer.usable_content?(extracted)
    rescue Nokogiri::CSS::SyntaxError
      false
    end

    def apply_conservative_limits!(definition)
      limits = definition["limits"].respond_to?(:to_h) ? definition["limits"].to_h.deep_stringify_keys : {}
      limits["max_items"] = [ limits.fetch("max_items", GENERATED_MAX_ITEMS).to_i, GENERATED_MAX_ITEMS ].min
      limits["interval_seconds"] = [ limits.fetch("interval_seconds", GENERATED_MIN_INTERVAL_SECONDS).to_i, GENERATED_MIN_INTERVAL_SECONDS ].max
      definition["limits"] = limits
    end

    def listing_prompt(entry_url, html)
      <<~PROMPT
        Generate one JSON crawl rule for a website listing page. Return JSON only.
        The rule is constrained to this schema:
        {
          "item_selector": "CSS selector for repeated list cards",
          "url": { "selector": "relative CSS selector", "attribute": "href" },
          "title": { "selector": "relative CSS selector" },
          "image": { "selector": "relative CSS selector", "attribute": "src" },
          "fields": { "published_at_text": { "selector": "relative CSS selector" } },
          "limits": { "max_items": 5, "interval_seconds": 10 },
          "url_policy": { "allow_path_prefixes": ["specific detail path prefix"], "strip_query_params": ["tracking parameter"] }
        }
        Rules: choose selectors that match actual repeated content, not navigation;
        URL links must be same-site article/event/detail links. Infer the narrowest
        path prefix and only observed tracking query parameters. Do not include a
        detail selector; it is generated and verified separately. Entry URL: #{entry_url}

        HTML:
        #{html.to_s.truncate(60_000)}
      PROMPT
    end

    def detail_prompt(url, html)
      <<~PROMPT
        Return JSON only: {"content_selector":"CSS selector"}.
        Select the single container holding the readable body of this article or
        event detail page. It may be a script[type="x-template"] container whose
        embedded HTML is the article body. Exclude navigation, registration forms,
        related items, and page-wide Vue/React templates. The selector must match
        a node in this HTML and contain substantive text or media.

        Detail URL: #{url}

        HTML:
        #{html.to_s.truncate(60_000)}
      PROMPT
    end

    class FerrumRenderer
      def fetch(url)
        options = {
          timeout: 30,
          process_timeout: 30,
          headless: true
        }
        options[:browser_path] = ENV["BROWSER_PATH"] if ENV["BROWSER_PATH"].present?
        browser = Ferrum::Browser.new(**options)
        browser.go_to(url)
        browser.network.wait_for_idle
        WebsiteCrawler::FetchResult.success(url: url, html: browser.body, status: 200)
      rescue StandardError => e
        WebsiteCrawler::FetchResult.failure(url: url, kind: :unsupported, error: "Ferrum 渲染失败: #{e.message}")
      ensure
        browser&.quit
      end
    end
  end
end
