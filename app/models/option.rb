class Option < ApplicationRecord
  cattr_reader :opt_validations, instance_reader: false, instance_accessor: false, default: {}
  cattr_reader :opt_descriptions, instance_reader: false, instance_accessor: false, default: {}
  cattr_reader :opt_types, instance_reader: false, instance_accessor: false, default: {}
  cattr_reader :opt_default_values, instance_reader: false, instance_accessor: false, default: {}
  cattr_reader :opt_keys, instance_reader: false, instance_accessor: false, default: []

  TYPES = [:string, :text, :boolean, :number]

  class << self
    def set_default_options
      def_option :crawler_verbose_mode,
                 true,
                 "Enable verbose logging for crawler operations",
                 type: :boolean

      def_option :crawler_log_retention_days,
                 7,
                 "Number of days to retain crawler logs",
                 type: :number
    end

    def def_option(key, val, desc = nil, opts = {})
      key = key.to_sym
      opt_validations[key] = opts[:validates]
      opt_descriptions[key] = desc
      opt_types[key] = opts[:type] || detect_type(val)
      opt_default_values[key] = val

      opt_keys << key unless opt_keys.include?(key)
    end

    def get_desc(key)
      raise "Undefined option key: #{key}" unless opt_keys.include?(key.to_sym)

      opt_descriptions[key.to_sym]
    end

    def get_value(key)
      if (opt = find_by(opt_key: key))
        value = opt.opt_value
      else
        value = opt_default_values[key]
        set_value(key, value) if value.present?
      end

      convert_value(value, get_type(key))
    end
    alias_method :[], :get_value

    def set_value(key, value)
      value = value.strip if value.is_a?(String)

      if (opt = find_by(opt_key: key))
        opt.update!(opt_value: value&.to_s)
      else
        create!(opt_key: key, opt_value: value&.to_s)
      end
    end
    alias_method :[]=, :set_value

    def get_type(key)
      raise "Undefined option key: #{key}" unless opt_keys.include?(key.to_sym)

      opt_types[key.to_sym]
    end

    def detect_type(value)
      case value
      when TrueClass, FalseClass
        :boolean
      when Numeric
        :number
      when String
        :string
      else
        raise "Unknown type for value #{value}. Its class is #{value.class}"
      end
    end

    def convert_value(value, type)
      case type
      when :string, :text
        value.to_s
      when :number
        value.to_f == value.to_i ? value.to_i : value.to_f
      when :boolean
        value.to_s == "true"
      else
        raise "Unknown type #{type} while convert value #{value}"
      end
    end

    def verbose_mode?
      self[:crawler_verbose_mode]
    end
  end

  set_default_options
end
