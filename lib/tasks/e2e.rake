# E2E 浏览器回归测试的数据库准备。由 bin/e2e 调用，不要手动跑：
# 任务会校验 E2E_DB_NAME 已设置（防止误操作开发库）。
namespace :e2e do
  desc "Seed the E2E database with deterministic fixture data (requires E2E_DB_NAME, run by bin/e2e)"
  task seed: :environment do
    require "e2e/seeder"
    E2e::Seeder.run!
  end

  desc "Truncate all tables in the E2E database for a fresh regression run (requires E2E_DB_NAME)"
  task reset_db: :environment do
    unless Rails.env.development? && ENV["E2E_DB_NAME"].present?
      abort("e2e:reset_db 只能在 development 且设置了 E2E_DB_NAME 时运行（由 bin/e2e 负责）。")
    end

    conn = ActiveRecord::Base.connection
    tables = conn.tables - %w[ar_internal_metadata schema_migrations]
    tables.each do |table|
      conn.execute("TRUNCATE TABLE #{conn.quote_table_name(table)} RESTART IDENTITY CASCADE")
    end
    puts "[e2e:reset_db] 已清空 #{tables.size} 张表（#{ENV['E2E_DB_NAME']}）"
  end
end
