class MigrateSystemConfigsToOptions < ActiveRecord::Migration[8.1]
  def up
    # Migrate data from system_configs to options
    say_with_time("Migrating system_configs data to options") do
      migrated = 0

      # Migrate each system_config entry to options
      execute("SELECT key, value, expires_at FROM system_configs").each do |row|
        key = row[0]
        value = row[1]
        expires_at = row[2]

        # Skip blank keys and duplicates
        next if key.blank?
        next if execute("SELECT 1 FROM options WHERE opt_key = '#{key}'").any?

        escaped_value = value.to_s.gsub("'", "''")
        execute("INSERT INTO options (opt_key, opt_value, created_at, updated_at) VALUES ('#{key}', '#{escaped_value}', datetime('now'), datetime('now'))")
        migrated += 1

        # Store expires_at for wechat_api_key as a separate option
        if key == 'wechat_api_key' && expires_at.present?
          escaped_expires = expires_at.to_s.gsub("'", "''")
          unless execute("SELECT 1 FROM options WHERE opt_key = 'wechat_api_key_expires_at'").any?
            execute("INSERT INTO options (opt_key, opt_value, created_at, updated_at) VALUES ('wechat_api_key_expires_at', '#{escaped_expires}', datetime('now'), datetime('now'))")
            migrated += 1
          end
        end
      end

      migrated
    end

    # Drop the system_configs table
    drop_table :system_configs
  end

  def down
    # Recreate system_configs table
    create_table :system_configs do |t|
      t.string :key, null: false
      t.text :value
      t.datetime :expires_at
      t.timestamps
    end
    add_index :system_configs, :key, unique: true

    # Migrate data back from options to system_configs
    say_with_time("Migrating options data back to system_configs") do
      migrated = 0
      system_config_keys = %w[wechat_api_key default_article_concurrency default_account_concurrency max_crawl_pages rednote_api_key]

      system_config_keys.each do |key|
        value = execute("SELECT opt_value FROM options WHERE opt_key = '#{key}'").first
        next unless value

        expires_at = nil
        if key == 'wechat_api_key'
          expires_row = execute("SELECT opt_value FROM options WHERE opt_key = 'wechat_api_key_expires_at'").first
          expires_at = expires_row[0] if expires_row
        end

        escaped_value = value[0].to_s.gsub("'", "''")
        if expires_at
          escaped_expires = expires_at.to_s.gsub("'", "''")
          execute("INSERT INTO system_configs (key, value, expires_at, created_at, updated_at) VALUES ('#{key}', '#{escaped_value}', '#{escaped_expires}', datetime('now'), datetime('now'))")
        else
          execute("INSERT INTO system_configs (key, value, created_at, updated_at) VALUES ('#{key}', '#{escaped_value}', datetime('now'), datetime('now'))")
        end
        migrated += 1
      end

      migrated
    end

    # Remove migrated wechat_api_key_expires_at from options
    execute("DELETE FROM options WHERE opt_key = 'wechat_api_key_expires_at'")
  end
end
