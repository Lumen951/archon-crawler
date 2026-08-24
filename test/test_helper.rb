ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...

    # 临时替换类方法（项目没有 mocha/webmock，沿用别名法打桩）。
    # 替换实现用 proc 传入，块留给测试正文：
    #   stub_class_method(Foo, :bar, ->(x) { "值" }) { ... }
    def stub_class_method(klass, name, replacement, &block)
      stub_class_methods(klass, { name => replacement }, &block)
    end

    # 一次替换多个类方法：
    #   stub_class_methods(Foo, bar: -> { 1 }, baz: ->(x) { x }) { ... }
    def stub_class_methods(klass, stubs)
      aliases = {}
      stubs.each do |name, replacement|
        original = :"__stubbed_original_#{name}"
        klass.singleton_class.alias_method original, name
        klass.singleton_class.define_method(name, &replacement)
        aliases[name] = original
      end
      yield
    ensure
      aliases.each do |name, original|
        klass.singleton_class.alias_method name, original
        klass.singleton_class.remove_method original
      end
    end

    # 在块内使用真实的内存缓存（test 环境默认是 :null_store，读永远拿不到写进去的值）
    def with_memory_cache
      previous = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      yield
    ensure
      Rails.cache = previous
    end
  end
end
