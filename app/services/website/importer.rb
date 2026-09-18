require "uri"

module Website
  # Imports WebsiteAccounts from textarea lines: "名称, URL" per line, or a
  # bare URL — the crawler fills the nickname from the site title on the
  # first crawl. One account per site (keyed by host with the leading www.
  # stripped).
  class Importer
    Result = Struct.new(:imported_count, :skipped_count, :invalid_count, :errors, :imported_account_ids, keyword_init: true)

    def self.import_lines(lines, crawl_mode: "sitemap")
      new.import_lines(lines, crawl_mode: crawl_mode)
    end

    def import_lines(lines, crawl_mode: "sitemap")
      crawl_mode = crawl_mode.to_s
      raise ArgumentError, "抓取模式只能是 sitemap 或 listing" unless %w[sitemap listing].include?(crawl_mode)

      result = Result.new(imported_count: 0, skipped_count: 0, invalid_count: 0, errors: [], imported_account_ids: [])
      seen = {}

      Array(lines).each do |line|
        name, url = parse_line(line)
        if url.blank?
          result.invalid_count += 1
          result.errors << "#{line.to_s.truncate(60)}: 无法识别的网址"
          next
        end

        fakeid = fakeid_for(url)
        if seen.key?(fakeid)
          result.skipped_count += 1
          next
        end
        seen[fakeid] = true

        account = ::WebsiteAccount.find_or_initialize_by(fakeid: fakeid)
        if account.new_record?
          account.nickname = name.presence || fakeid
          account.metadata = { "url" => url }
          account.crawl_rule = { "mode" => crawl_mode }
          account.status = crawl_mode == "listing" ? :inactive : :active
          account.total_articles = 0

          if account.save
            result.imported_count += 1
            result.imported_account_ids << account.id
          else
            result.errors << "#{fakeid}: #{account.errors.full_messages.join(', ')}"
          end
        else
          result.skipped_count += 1
        end
      end

      result
    end

    private

    # "名称, https://example.com" (half/full-width comma or tab) or a bare URL.
    def parse_line(line)
      parts = line.to_s.split(/[,，\t]/).map(&:strip).reject(&:blank?)
      url = normalize_url(parts.last)
      name = parts.size >= 2 ? parts.first : nil
      [name, url]
    end

    def normalize_url(value)
      value = value.to_s.strip
      return nil if value.empty?

      value = "https://#{value}" unless value.match?(%r{\Ahttps?://}i)

      uri = URI.parse(value)
      return nil unless uri.host.present? && %w[http https].include?(uri.scheme)

      uri.fragment = nil
      uri.query = nil
      uri.path = uri.path.chomp("/")
      uri.to_s
    rescue URI::Error
      nil
    end

    # Host with the leading www. stripped — the account key.
    def fakeid_for(url)
      URI.parse(url).host.to_s.downcase.sub(/\Awww\./, "")
    end
  end
end
