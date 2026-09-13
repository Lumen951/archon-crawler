# == Schema Information
#
# Table name: tag_accounts
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  account_id :bigint           not null
#  tag_id     :bigint           not null
#
# Indexes
#
#  index_tag_accounts_on_account_id             (account_id)
#  index_tag_accounts_on_tag_id                 (tag_id)
#  index_tag_accounts_on_tag_id_and_account_id  (tag_id,account_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (tag_id => tags.id)
#
class TagAccount < ApplicationRecord
  belongs_to :tag, counter_cache: true
  belongs_to :account

  validates :account_id, uniqueness: { scope: :tag_id }
end
