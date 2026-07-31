class AddMetadataToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :metadata, :jsonb, default: {}
    add_index  :accounts, :metadata, using: :gin
  end
end
