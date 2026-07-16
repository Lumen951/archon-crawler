require "csv"

module Rednote
  class Importer
    # Supported formats:
    # JSON: array or { "accounts": [...] } / { "users": [...] }
    #   fields: user_id, nickname (or name), avatar (or image)
    # CSV: columns user_id, name, image (as exported by candidate review tool)
    #   duplicate user_ids within the same file are de-duplicated automatically

    SUPPORTED_FILE_TYPES = %w[.json .csv].freeze

    Result = Struct.new(:imported_count, :skipped_count, :invalid_count, :errors, keyword_init: true)

    def self.import_text(text)
      new.import_text(text)
    end

    def self.import_file(file)
      new.import_file(file)
    end

    # Import from search results (profile ID lookup).
    # rows: array of hashes with "user_id", "nickname", "image"
    def self.import_search_rows(rows)
      result = Result.new(imported_count: 0, skipped_count: 0, invalid_count: 0, errors: [])

      rows.each do |raw_row|
        attrs = {
          fakeid:   raw_row["user_id"].to_s.strip.presence,
          nickname: raw_row["nickname"].to_s.strip.presence,
          avatar:   raw_row["image"].to_s.strip.presence
        }

        unless attrs[:fakeid].present? && attrs[:nickname].present?
          result.invalid_count += 1
          next
        end

        account = ::RednoteAccount.find_or_initialize_by(fakeid: attrs[:fakeid])

        if account.new_record?
          account.nickname       = attrs[:nickname]
          account.round_head_img = attrs[:avatar]
          account.status         = :active
          account.total_articles = 0

          if account.save
            result.imported_count += 1
          else
            result.errors << "#{attrs[:nickname]}: #{account.errors.full_messages.join(', ')}"
          end
        else
          result.skipped_count += 1
        end
      end

      result
    end

    def import_text(text)
      import_rows(parse_json(text))
    end

    def import_file(file)
      extension = File.extname(original_filename_for(file)).downcase
      raise ArgumentError, "仅支持 .json、.csv 文件" unless SUPPORTED_FILE_TYPES.include?(extension)

      rows = case extension
      when ".json" then parse_json(read_content(file))
      when ".csv"  then parse_csv(read_content(file))
      end

      import_rows(rows)
    end

    private

    def import_rows(rows)
      result = Result.new(imported_count: 0, skipped_count: 0, invalid_count: 0, errors: [])

      rows.each do |raw_row|
        attrs = normalize_row(raw_row)

        unless attrs[:fakeid].present? && attrs[:nickname].present?
          result.invalid_count += 1
          next
        end

        account = ::RednoteAccount.find_or_initialize_by(fakeid: attrs[:fakeid])

        if account.new_record?
          account.nickname       = attrs[:nickname]
          account.round_head_img = attrs[:avatar]
          account.status         = :active
          account.total_articles = 0

          if account.save
            result.imported_count += 1
          else
            result.errors << "#{attrs[:nickname]}: #{account.errors.full_messages.join(', ')}"
          end
        else
          result.skipped_count += 1
        end
      end

      result
    end

    def normalize_row(row)
      row = row.transform_keys(&:to_s) if row.respond_to?(:transform_keys)
      {
        fakeid:   row["user_id"].to_s.strip.presence,
        nickname: (row["nickname"] || row["name"]).to_s.strip.presence,
        avatar:   (row["avatar"]   || row["image"]).to_s.strip.presence
      }
    end

    def parse_json(content)
      json = JSON.parse(content)
      case json
      when Array then json
      when Hash
        list = json["accounts"] || json["users"]
        raise ArgumentError, '无效的 JSON 格式。期望数组或包含 "accounts" 键的对象' unless list.is_a?(Array)
        list
      else
        raise ArgumentError, "无效的 JSON 格式"
      end
    rescue JSON::ParserError => e
      raise ArgumentError, "无效的 JSON 格式：#{e.message}"
    end

    # Parse CSV exported by candidate review tool.
    # Required column: user_id. Optional: name, image.
    # Deduplicates by user_id (keeps first occurrence).
    def parse_csv(content)
      content = content.sub("\xEF\xBB\xBF", "") # strip BOM if present
      csv = CSV.parse(content, headers: true, strip: true)
      seen = Set.new
      csv.filter_map do |row|
        uid = row["user_id"].to_s.strip
        next if uid.blank? || seen.include?(uid)
        seen << uid
        { "user_id" => uid, "name" => row["name"].to_s.strip, "image" => row["image"].to_s.strip }
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
