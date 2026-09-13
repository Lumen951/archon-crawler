# == Schema Information
#
# Table name: groups
#
#  id         :bigint           not null, primary key
#  name       :string
#  ref_key    :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
# Indexes
#
#  index_groups_on_user_id              (user_id)
#  index_groups_on_user_id_and_ref_key  (user_id,ref_key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class Group < ApplicationRecord
  belongs_to :user
  has_many :group_accounts, dependent: :destroy
  has_many :accounts, through: :group_accounts

  validates :ref_key, presence: true,
                      format: { with: /\A[a-zA-Z0-9_-]+\z/, message: "只能包含字母、数字、下划线和连字符" }
  validates :ref_key, uniqueness: { scope: :user_id, message: "该用户已存在相同的 ref_key" }
end
