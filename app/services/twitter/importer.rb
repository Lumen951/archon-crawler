require "csv"

module Twitter
  class Importer
    # Supported formats:
    # CSV: columns screen_name (required), user_id (optional), name (optional), image (optional)
    #   If user_id is missing, it is looked up via TwitterApiClient.lookup_user
    #   Duplicate screen_names/user_ids within the same file are de-duplicated

    Result = Struct.new(:imported_count, :skipped_count, :invalid_count, :errors, keyword_init: true)

    def self.import_file(file)
      new.import_file(file)
    end

    def self.import_search_rows(rows)
      new.import_search_rows(rows)
    end

    def import_file(file)
      extension = File.extname(original_filename_for(file)).downcase
      raise ArgumentError, "仅支持 .csv 文件" unless extension == ".csv"

      rows = parse_csv(read_content(file))
      import_rows(rows)
    end

    def import_search_rows(rows)
      raise ArgumentError, "请至少选择一个帐号" if rows.blank?

      import_rows(rows)
    end

    private

    def import_rows(rows)
      result = Result.new(imported_count: 0, skipped_count: 0, invalid_count: 0, errors: [])

      rows.each do |raw_row|
        attrs = normalize_row(raw_row)

        # Need at least screen_name or user_id
        if attrs[:screen_name].blank? && attrs[:user_id].blank?
          result.invalid_count += 1
          next
        end

        # If user_id is missing, look it up by screen_name
        if attrs[:user_id].blank? && attrs[:screen_name].present?
          attrs = lookup_user_id(attrs)
        end

        if attrs[:user_id].blank?
          result.errors << "#{attrs[:screen_name] || '(未知)'}: 无法获取 user_id"
          result.invalid_count += 1
          next
        end

        account = ::TwitterAccount.find_or_initialize_by(fakeid: attrs[:user_id])

        if account.new_record?
          account.nickname            = attrs[:name].presence || attrs[:screen_name]
          account.twitter_screen_name = attrs[:screen_name]&.downcase
          account.round_head_img      = attrs[:image]
          account.status         = :active
          account.total_articles = 0

          if account.save
            result.imported_count += 1
          else
            result.errors << "#{attrs[:screen_name]}: #{account.errors.full_messages.join(', ')}"
          end
        else
          result.skipped_count += 1
        end
      end

      result
    end

    def lookup_user_id(attrs)
      users = TwitterApiClient.lookup_user(attrs[:screen_name])
      if users.is_a?(Array) && users.first
        user = users.first
        attrs[:user_id] = user["rest_id"]&.to_s
        attrs[:name] ||= user["name"]
        attrs[:image] ||= user["profile_image_url_https"]
      end
      attrs
    rescue TwitterApiClient::ApiError => e
      Rails.logger.warn("Twitter lookup failed for @#{attrs[:screen_name]}: #{e.message}")
      attrs
    end

    def normalize_row(row)
      row = row.transform_keys(&:to_s) if row.respond_to?(:transform_keys)
      {
        user_id:   row["user_id"].to_s.strip.presence,
        screen_name: (row["screen_name"] || row["username"] || row["handle"]).to_s.strip.delete_prefix("@").presence,
        name:      (row["name"] || row["display_name"]).to_s.strip.presence,
        image:     (row["image"] || row["avatar"] || row["profile_image_url_https"]).to_s.strip.presence
      }
    end

    def parse_csv(content)
      content = content.sub("\xEF\xBB\xBF", "") # strip BOM if present
      csv = CSV.parse(content, headers: true, strip: true)
      seen = Set.new
      csv.filter_map do |row|
        # Dedup by screen_name (case-insensitive) or user_id
        key = row["user_id"].to_s.strip.presence || row["screen_name"].to_s.strip.downcase.delete_prefix("@")
        next if key.blank? || seen.include?(key)
        seen << key
        row.to_h
      end
    rescue CSV::MalformedCSVError => e
      raise ArgumentError, "CSV 格式错误：#{e.message}"
    end

    def read_content(file)
      if file.respond_to?(:read)
        file.read.force_encoding("UTF-8")
      else
        File.read(file, encoding: "UTF-8")
      end
    end

    def original_filename_for(file)
      file.respond_to?(:original_filename) ? file.original_filename : file.to_s
    end
  end
end
