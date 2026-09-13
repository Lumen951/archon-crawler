# == Schema Information
#
# Table name: group_accounts
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  account_id :bigint           not null
#  group_id   :bigint           not null
#
# Indexes
#
#  index_group_accounts_on_account_id               (account_id)
#  index_group_accounts_on_group_id                 (group_id)
#  index_group_accounts_on_group_id_and_account_id  (group_id,account_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (group_id => groups.id)
#
class GroupAccount < ApplicationRecord
  belongs_to :group
  belongs_to :account

  validates :account_id, uniqueness: { scope: :group_id, message: "该帐号已在此分组中" }
end
