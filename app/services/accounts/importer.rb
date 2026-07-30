require "csv"

module Accounts
  class Importer
    SUPPORTED_FILE_TYPES = %w[.json .csv .xlsx].freeze
    REQUIRED_HEADERS = %w[fakeid nickname].freeze
    OPTIONAL_HEADER_MAP = {
      "round_head_img" => :round_head_img,
      "articles" => :total_articles,
      "total_articles" => :total_articles
    }.freeze

    Result = Struct.new(:imported_count, :skipped_count, :invalid_count, :errors, keyword_init: true)

    def self.import_text(text)
      new.import_text(text)
    end

    def self.import_file(file)
      new.import_file(file)
    end

    def self.import_search_rows(rows)
      new.import_search_rows(rows)
    end

    def import_text(text)
      import_rows(parse_json(text))
    end

    def import_file(file)
      extension = File.extname(original_filename_for(file)).downcase

      unless SUPPORTED_FILE_TYPES.include?(extension)
        raise ArgumentError, "仅支持 .json、.csv、.xlsx 文件"
      end

      rows = case extension
      when ".json"
        parse_json(read_content(file))
      when ".csv"
        parse_csv(read_content(file))
      when ".xlsx"
        parse_xlsx(file)
      end

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
        attributes = normalize_row(raw_row)

        unless attributes[:fakeid].present? && attributes[:nickname].present?
          result.invalid_count += 1
          next
        end

        account = WechatAccount.find_or_initialize_by(fakeid: attributes[:fakeid])

        if account.new_record?
          account.nickname = attributes[:nickname]
          account.round_head_img = attributes[:round_head_img]
          account.status = :active
          account.total_articles = attributes[:total_articles] || 0

          if account.save
            result.imported_count += 1
          else
            result.errors << "#{attributes[:nickname]}: #{account.errors.full_messages.join(', ')}"
          end
        else
          result.skipped_count += 1
        end
      end

      result
    end

    def parse_json(content)
      json = JSON.parse(content)

      unless json.is_a?(Hash) && json["accounts"].is_a?(Array)
        raise ArgumentError, '无效的 JSON 格式。期望结构：{ "accounts": [...] }'
      end

      json.fetch("accounts")
    rescue JSON::ParserError => e
      raise ArgumentError, "无效的 JSON 格式：#{e.message}"
    end

    def parse_csv(content)
      table = CSV.parse(content, headers: true)
      header_map = build_header_map(table.headers || [])
      validate_required_headers!(header_map)

      table.map do |row|
        extract_row(row.to_h, header_map)
      end
    end

    def parse_xlsx(file)
      workbook = Roo::Spreadsheet.open(path_for(file), extension: :xlsx)
      sheet = workbook.sheet(0)
      header_map = build_header_map(sheet.row(1))
      validate_required_headers!(header_map)

      sheet.parse(headers: true).drop(1).map do |row|
        extract_row(row, header_map)
      end
    rescue Zip::Error, IOError => e
      raise ArgumentError, "无效的 XLSX 文件：#{e.message}"
    end

    def build_header_map(headers)
      headers.each_with_object({}) do |header, map|
        normalized = normalize_header(header)
        next if normalized.blank?

        if REQUIRED_HEADERS.include?(normalized) || OPTIONAL_HEADER_MAP.key?(normalized)
          map[normalized] = header
        end
      end
    end

    def validate_required_headers!(header_map)
      missing_headers = REQUIRED_HEADERS.reject { |header| header_map.key?(header) }
      return if missing_headers.empty?

      raise ArgumentError, "文件缺少必填列：#{missing_headers.join(', ')}"
    end

    def extract_row(row, header_map)
      {
        fakeid: value_from(row, header_map["fakeid"]),
        nickname: value_from(row, header_map["nickname"]),
        round_head_img: value_from(row, header_map["round_head_img"]),
        total_articles: parse_integer(value_from(row, header_map["articles"]) || value_from(row, header_map["total_articles"]))
      }
    end

    def normalize_row(row)
      if row.is_a?(Hash) && row.keys.any? { |key| key.is_a?(Symbol) }
        row.transform_values { |value| normalize_value(value) }
      else
        extract_row(row, build_header_map(row.keys))
      end
    end

    def normalize_header(header)
      header.to_s.strip.downcase.gsub(/[\s-]+/, "_")
    end

    def value_from(row, key)
      normalize_value(row[key])
    end

    def normalize_value(value)
      return if value.nil?

      if value.is_a?(String)
        ensure_utf8(value).strip.presence
      else
        value.presence
      end
    end

    def ensure_utf8(value)
      value.dup.force_encoding(Encoding::UTF_8).encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
    end

    def parse_integer(value)
      return nil if value.blank?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def read_content(file)
      rewind(file)
      ensure_utf8(file.read).tap { rewind(file) }
    end

    def rewind(file)
      file.rewind if file.respond_to?(:rewind)
      file.tempfile.rewind if file.respond_to?(:tempfile) && file.tempfile.respond_to?(:rewind)
    end

    def original_filename_for(file)
      return file.original_filename if file.respond_to?(:original_filename) && file.original_filename.present?
      return File.basename(file.path) if file.respond_to?(:path) && file.path.present?
      return File.basename(file.tempfile.path) if file.respond_to?(:tempfile) && file.tempfile.respond_to?(:path)

      raise ArgumentError, "无法读取上传文件"
    end

    def path_for(file)
      return file.tempfile.path if file.respond_to?(:tempfile) && file.tempfile.respond_to?(:path)
      return file.path if file.respond_to?(:path) && file.path.present?

      raise ArgumentError, "无法读取上传文件"
    end
  end
end
