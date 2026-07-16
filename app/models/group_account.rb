class GroupAccount < ApplicationRecord
  belongs_to :group
  belongs_to :account

  validates :account_id, uniqueness: { scope: :group_id, message: "该帐号已在此分组中" }
end
