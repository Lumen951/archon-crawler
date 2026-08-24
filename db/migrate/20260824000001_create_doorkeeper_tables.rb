# frozen_string_literal: true

# OAuth 2.1 authorization server tables (Doorkeeper).
#
# Deviations from the stock Doorkeeper migration, all driven by the MCP
# authorization spec (2026-07-28):
#
#   * `oauth_applications.secret` is nullable — MCP clients register themselves
#     through Dynamic Client Registration (RFC 7591) as *public* clients and
#     authenticate with PKCE instead of a secret.
#   * PKCE columns are folded in here rather than in a follow-up migration.
#   * `resource` columns implement Resource Indicators (RFC 8707): the value the
#     client passes at authorization time is carried onto the access token so the
#     resource server can validate the token's audience.
class CreateDoorkeeperTables < ActiveRecord::Migration[8.1]
  def change
    create_table :oauth_applications do |t|
      t.string  :name,         null: false
      t.string  :uid,          null: false
      t.string  :secret
      t.text    :redirect_uri, null: false
      t.string  :scopes,       null: false, default: ""
      t.boolean :confidential, null: false, default: true
      t.timestamps             null: false
    end

    add_index :oauth_applications, :uid, unique: true

    create_table :oauth_access_grants do |t|
      t.references :resource_owner, null: false
      t.references :application,    null: false
      t.string   :token,            null: false
      t.integer  :expires_in,       null: false
      t.text     :redirect_uri,     null: false
      t.string   :scopes,           null: false, default: ""
      t.datetime :created_at,       null: false
      t.datetime :revoked_at

      # PKCE (RFC 7636) — required for every MCP client.
      t.string   :code_challenge
      t.string   :code_challenge_method

      # Resource Indicators (RFC 8707).
      t.string   :resource
    end

    add_index :oauth_access_grants, :token, unique: true
    add_foreign_key :oauth_access_grants, :oauth_applications, column: :application_id
    add_foreign_key :oauth_access_grants, :users, column: :resource_owner_id

    create_table :oauth_access_tokens do |t|
      t.references :resource_owner, index: true
      t.references :application,    null: false

      t.string   :token,      null: false
      t.string   :refresh_token
      t.integer  :expires_in
      t.string   :scopes
      t.datetime :created_at, null: false
      t.datetime :revoked_at

      # Present so Doorkeeper revokes a refresh token only after its replacement
      # has actually been used (refresh token rotation).
      t.string   :previous_refresh_token, null: false, default: ""

      # Resource Indicators (RFC 8707) — copied from the grant.
      t.string   :resource
    end

    add_index :oauth_access_tokens, :token, unique: true
    add_index :oauth_access_tokens, :refresh_token, unique: true
    add_foreign_key :oauth_access_tokens, :oauth_applications, column: :application_id
    add_foreign_key :oauth_access_tokens, :users, column: :resource_owner_id
  end
end
